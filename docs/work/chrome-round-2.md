# Browser chrome, round 2: the failures you cannot see

The chrome **passed** its kill criterion five for five — the URL is visible and
editable, back and reload work, and hovering a link shows where it goes. This is
what a fresh critic found anyway, ranked as it ranked them. Blocked on the
motion round-2 work merging, which owns `Web/WebPaneController.swift`.

## 1. A navigation that fails produces no feedback of any kind

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

## 2. Public-internet `http://` does not load at all

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

## 3. ⌘L is dead, and the comment saying it is taken is stale

Four attempts, two fresh instances, both focus states: nothing. There is no
`focusAddressBar` in `Commands.swift`. The comment in `WebPaneController` says
⌘L "already means something else here (`newWebLane`)" — it does not; that
binding is gone. **The key is free.**

⌘O is not a substitute: its header reads "→ new lane", because it *adds* a lane
rather than retargeting the one you are reading. So "change where this lane
points" is currently mouse-only.

## 4. ⌘-click and middle-click navigate in place

Confirmed on two instances — `maxpane ls` showed one pane before and after, only
the title changed. The critic's words: *this is the expensive kind: you reach
for "keep my place, open a sibling" and instead you lose your place.*

The capability is already built and correct — WebKit's own context menu item
"Open Link in New Window" produces `window.open … → popup → materialize lane`
and a new lane to the right. Only the modifiers are not wired to it.

## 5. An untitled page keeps the previous page's title

`adoptTitle` early-returns on an empty title, so five navigations through pages
with no `<title>` left the header reading `Computer program – Wikipedia`. This
owner's lanes hold localhost dev servers, raw JSON and text files, and the lane
header is what he scans across six columns. Falling back to host plus path would
fix it.

## 6. Smaller

- **No address-bar autocomplete.** `en.wik` offers nothing. ⌘O has the URLs but
  it is a different surface with a different outcome.
- **Find has no match count.** ⌘F works well — live filtering, Enter advances,
  ↑/↓, Escape dismisses, `no match` in orange — but with matches there is no
  `3/17`, so one hit and forty look the same. Noted in round 1 as deliberate,
  because `WKWebView.find` has no count and inventing one would be a lie; worth
  revisiting whether it can be counted honestly.
- **Long URLs clip with no ellipsis**, stopping mid-word. Mitigated by stripping
  the scheme and `www.`: at a 420pt lane
  `github.com/rust-lang/rust/pull/135000/files` still fits whole.
- **No bookmarks.** The substitute is ⌘O recents plus pinned lanes. A defensible
  model change, and still a thing he uses eight of every day.
- **⌘[ / ⌘] collide with Chrome/Safari's back/forward** in the fingers. ⌘← / ⌘→
  do work; the collision is deliberate and documented, but with two lanes open
  ⌘[ silently jumps lanes when he meant back.
- **Right-click is the stock WebKit menu**: "Open Link in New Window" is the
  wrong noun for what happens, and there is no "open right of here".

## Disputed, re-check before acting

The critic reports **no zoom readout**; the builder reports a `125%` chip that
fades in whenever zoom is off 100%. The code is intact —
`WebChromeBar.setZoom` sets the glyph and fades the chip in, and
`WebPaneController` calls it both on init and in `setZoom`. Either the chip is
too quiet to find or the critic's zoom presses reached a terminal pane. Look
before changing anything.
