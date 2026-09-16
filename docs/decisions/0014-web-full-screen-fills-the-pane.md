# ADR 0014 — A page's full screen fills its pane; ⇧ or a second request goes to the display

**Status:** Accepted · 2026-09-13
**Decides:** what happens when a web page asks for full screen, and the points
where building it departed from its work item.
**Evidence:** the work item
[`docs/work/web-fullscreen-in-pane.md`](../work/web-fullscreen-in-pane.md), whose
design is the owner's and is not re-opened here; and `WebFullscreenTests.swift`,
which drives it through real WebKit with two local origins.

## Decision

`WKWebViewConfiguration.preferences.isElementFullscreenEnabled` is now on. It is
off by default, so the Fullscreen API did not exist and every video site either
hid ⤢ or said the browser could not do full screen. On, it is WebKit's own full
screen across the display, and that is kept as the second step.

The first step is `PaneFullscreen`: a user script in the page's world, at
document start, in every frame. It answers the API itself (`requestFullscreen`
and its `webkit` spellings, `exitFullscreen`, `fullscreenElement`,
`fullscreenEnabled`, `webkitIsFullScreen`, `webkitEnterFullscreen` on a video).
A request pins the element to the viewport, which is the web view, which is the
pane. Its top frame posts `{active}` to `WebPaneController`, which gives the page
the bars' height and fades the chrome, find and download bars out.

What the tests hold, against real WebKit, with a host page and an embed page
served from two loopback ports, the host in the top pane of a split lane:

- With the preference on, WebKit's own `fullscreenEnabled` reads true. That was
  read by a recorder script before the shim replaced the getter.
- `box.requestFullscreen()` resolves. `fullscreenElement` and
  `webkitFullscreenElement` name the box, and `fullscreenchange` then
  `webkitfullscreenchange` fire. The box's rect is exactly the web view's bounds,
  and the web view is exactly the pane.
- The box sits inside a card with a `transform` and `overflow: hidden`, and a
  later sibling has a higher `z-index`. `elementFromPoint` still finds the box on
  top, so the manual popover did escape the card.
- The page's own `#box:fullscreen` rule and a `:-webkit-full-screen` rule inside
  `@media` both apply to the pinned box.
- The pane's frame, its sibling's frame, its sibling's web view and its sibling's
  bar do not change. `fullscreenState` stays `.notInFullscreen` throughout.
- `exitFullscreen()` restores the box's rect exactly and fires both events again
  with `fullscreenElement` null. The bars come back at alpha 1.
- Esc, as an `NSEvent` delivered to the web view, ends it. The page's own
  `keydown` listener counts zero Escapes, because a browser takes that Esc from
  the page.
- In a cross-origin `<iframe>` without `allow="fullscreen"`, WebKit's
  `fullscreenEnabled` reads false through the shim and a request is refused. In
  one with it, the player fills its frame and the `<iframe>` element fills the
  pane. Exiting from the page around it tells the player (`in|out`), exiting from
  the player unwinds the page, and both leave the `<iframe>` at 300 × 200 again.
- A request while the pane is already full screen, or a click with `shiftKey`,
  reaches the kept native function. The recorder logs the calls, and the pane
  stays untouched on ⇧.
- Loading another page while full screen brings the bar back.
- `setPaneFullscreen` changes the web view's size at once. The bars are still
  visible and fading afterwards, unless Reduce Motion is on.
- In a popup's page, an element fills the dialog's page at 500 × 600 and the
  origin bar stays at alpha 1. The first Esc leaves full screen and a second one
  closes the dialog.

## Where the build departed from the work item

1. **An attribute, not a class, and the top layer, not only `position: fixed`.**
   The item said "a class plus an injected sheet". A framework that re-renders
   `className` would strip a class from a playing video, so the pinned element
   wears `data-maxpane-fullscreen`. A fixed element inside a transformed
   ancestor is fixed to that ancestor rather than the viewport, and players sit
   in exactly such cards. So the element goes into the top layer as a manual
   popover. Only where that is impossible, because the element is already a
   popover or has no `showPopover`, is it fixed at the highest `z-index`.
2. **`:fullscreen` rules are copied, not matched.** A pseudo-class cannot be set
   from script. At each request, every style sheet not walked yet has its
   `:fullscreen` and `:-webkit-full-screen` rules copied onto the attribute,
   including those inside `@media`, `@supports` and `@layer`. A sheet from
   another origin cannot be read and is skipped.
3. **The page's size changes at once, and only the bars move.** The item said
   the bars "ease out of the way". Growing the web view a frame at a time would
   reflow a video player a dozen times to arrive where one reflow puts it. So
   the constraint flips, and the bars fade over a page that is already its final
   size, on `Motion.pane` with ease-out, or instantly under Reduce Motion. They
   fade rather than slide, because the pane does not clip and a sliding bar would
   draw across the pane below it in a split. Once invisible they are hidden, so
   nothing under a video takes a click.
4. **Keys that need the bar leave full screen first.** ⌘L, ⌘F and Keep This Page all open
   something in or over the bar that the video is covering, so each of them
   calls the page's own `exitFullscreen` before it acts. The app claims no new
   key. Esc is still the page's (`WebPaneKeyRoutingTests` passes unchanged), and
   the shim takes it inside the page, as a browser would.
5. **"Navigates away" means a committed load.** `didCommit` ends it, and so do
   the page's process dying, eviction and closing the pane. `pushState` never
   commits, so a single-page player changing its URL keeps its full screen.
6. **A request needs a gesture.** A request without `navigator.userActivation`
   is refused with `fullscreenerror`, as browsers do. In real WebKit a script run
   by the app through `callAsyncJavaScript` counts as an activation, which is
   how the tests request full screen at all. The refusal itself is not
   exercised.
7. **Inside a popup, the dialog's page fills and its bar stays.** The popup's
   web view shares the opener's content controller, because WebKit copies it
   into the configuration it hands over, so the popup's messages arrive at the
   opener pane. They are routed to `WebPopupDialog.pageIsFullscreen`, and the
   pane's bar is not touched. The origin bar stays because it is the one row the
   page cannot draw; a page that could hide it on request could pretend to be any
   site. `Popup`'s Esc monitor sees the key before the page, so the dialog asks
   the page to leave full screen before it closes.

## Found on the way

- **A popup's first document gets no document-start scripts.** A popup opens on
  an empty `about:blank` that is already `complete`, and nothing injected at
  document start runs in it. A request made there skipped the shim and got
  WebKit's own answer: "Cannot request fullscreen in a hidden document". The
  real page that follows has the shim. The test now waits for the provider's
  own script.
- **`WKUserContentController.userScripts` is live.** Re-adding its own elements
  while iterating it never ends. The first version of the test fixture did that
  to put the recorder in front, and the test process grew until the system
  killed it with no message, filling the disk with swap on the way. The fixture
  now rebuilds the scripts into a Swift array first.

## Rejected

- **WebKit's own full screen for every request.** It takes the whole display,
  one step further than a column of the strip wants to go on a click. The owner
  decided this, and it is kept as the second step.
- **Resizing the lane or the pane to make the video bigger.** The constraint is
  "the pane's available area". Full screen never changes the strip.
- **Redirecting WebKit's full screen into the pane.** There is no public API for
  hosting an element's full screen in a view. The private full-screen delegate
  is SPI that a WebKit release can take away.

## Not verified

- YouTube itself. It needs the network and plays ads, so the owner checks ⤢ on a
  real video after installing.
- WebKit's own full screen across the display. The tests stand a recorder in
  front of it so it never takes over the screen.
- The app itself. No instance was launched, because entering full screen there
  needs a click in a page.
- `:fullscreen` rules in a cross-origin style sheet, which the shim cannot read.
- The refusal of a request made without a gesture.

## Revisit when

A site's player breaks under the shim, WebKit gives `WKWebView` a public way to
host element full screen in a view, or a sheet loaded after the first request
turns out to carry the only `:fullscreen` rules.
