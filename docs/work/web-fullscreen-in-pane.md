# A page's full screen fills its pane; ⇧ or a second request goes real full screen

The owner, with a screenshot of YouTube saying *"Your browser doesn't support full
screen"*: *"when I try to make a youtube view (or any browser view) full screen.
It's telling me my browser doesn't support it. I'd like to give the webview access
to the pane's available area. Is that possible?"*

## Problem

Nothing in the app handles the Fullscreen API. `WKWebViewConfiguration` is built at
`Web/WebPaneController.swift` ~939 without `preferences.isElementFullscreenEnabled`,
which WebKit leaves off by default — so `document.fullscreenEnabled` is false,
`requestFullscreen` is inert, and every video site either hides its ⤢ button or
says the browser cannot do it. The app targets macOS 14; the preference exists from
12.3.

## Decisions already made (do not re-open)

- **A fullscreen request fills the pane**, not the display: the requesting element
  takes the pane's whole web area, the pane's own chrome bar (and find bar) eases
  out of the way, the lane header and the strip stay exactly where they are, and
  the lanes beside it keep running. Esc, or the page's own exit control, restores it.
- **Real macOS full screen is one more step away:** a fullscreen request made while
  the pane is already pane-fullscreen, or made with ⇧ held on the gesture that
  triggered it, goes to WebKit's native full screen across the display. Esc from
  there returns the page to normal.

## Design notes

- Turn on `isElementFullscreenEnabled`, which makes the API exist and gives the
  native path.
- Pane fullscreen is a **page-world user script at document start in every frame**
  that answers the Fullscreen API itself: `requestFullscreen` /
  `webkitRequestFullscreen` / `webkitEnterFullscreen`, `exitFullscreen` /
  `webkitExitFullscreen`, `fullscreenElement` / `webkitFullscreenElement` /
  `webkitIsFullScreen` / `fullscreenEnabled`, firing `fullscreenchange` and
  `webkitfullscreenchange` on the element and the document the way a browser does,
  and resolving the promise. The element is pinned to the viewport with a style the
  script owns, and `:fullscreen` styling is emulated with a class plus an injected
  sheet, because sites style their full-screen player through that selector.
- It keeps references to the **native** functions, and the "second request / ⇧" path
  calls those. ⇧ is read from the gesture's own event, tracked by a capture-phase
  listener, since `requestFullscreen` carries no event.
- **Embedded players:** a cross-origin iframe (a YouTube embed on another site) can
  only fill its own frame. The script in each frame tells the one in its parent, so
  the parent pins the `<iframe>` element to the pane as well. Same script, both
  ends.
- Pane state crosses to Swift through a script message handler, for hiding the
  chrome bar, eased on `Motion`, and for ending pane fullscreen when the page
  navigates away, reloads or the pane closes.
- The shim runs in the page's world, because it must replace the page's own
  prototypes. `PasswordFill`'s isolated content world stays as it is.

## Acceptance Criteria

- Real WebKit, local test pages:
  - `document.fullscreenEnabled` is true;
  - `el.requestFullscreen()` on a video-like element makes it cover the web view's
    bounds exactly, `document.fullscreenElement === el`, `fullscreenchange` fires,
    the promise resolves, and the pane, lane and strip do not change size;
  - `document.exitFullscreen()` and Esc both restore the element's original layout
    and fire `fullscreenchange` again, with `fullscreenElement` null;
  - a cross-origin `<iframe allow="fullscreen">` whose inner element requests full
    screen ends up filling the pane;
  - a request made while already pane-fullscreen, or with ⇧ held, calls the native
    path — checked through `WKWebView.fullscreenState` (macOS 13+) rather than by
    looking at the screen;
  - navigating away while pane-fullscreen restores the chrome bar.
- The chrome bar and find bar hide and return with an eased transition, honouring
  Reduce Motion.
- `WebPaneKeyRoutingTests`' rule still holds: Esc belongs to the page and the app
  claims nothing new.
- A split lane: only the requesting pane fills, and its siblings are untouched.
- README: a paragraph in the web-pane section ("Full screen fills the pane; ⇧ for the
  display").
- YouTube itself cannot be the test (network, account); say so, and have the owner
  check ⤢ on the video in the screenshot after installing.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` — configuration
  (~939), user scripts and message handlers, navigation/close hooks.
- `swift/MaxPane/Sources/MaxPaneKit/Views/WebChromeBar.swift`, `Views/WebFindBar.swift`
  — what hides while pane-fullscreen.
- `swift/MaxPane/Sources/MaxPaneKit/Web/LinkHoverProbe.swift` — an existing injected
  script to follow for style.
- `swift/MaxPane/Sources/MaxPaneKit/Passwords/PasswordFill.swift` — the isolated
  world, which this must not disturb.
- `swift/MaxPane/Tests/MaxPaneKitTests/WebPaneKeyRoutingTests.swift` — Esc stays with
  the page.

## Constraints

- Never resize the lane, the pane or the strip to make a video bigger. Pane
  fullscreen is "the pane's available area".
- Nothing appears or disappears abruptly (`Motion`, Reduce Motion).
- `Web/WebPaneAsks.swift` holds another session's uncommitted edit; do not
  overwrite, stage or revert it.
- Queued after the web-popups task; both touch `WebPaneController`, so build on
  whatever that one landed.
