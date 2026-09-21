# YouTube in a web pane: the first Play gives no sound until the video is clicked again

## Problem

The owner (2026-09-21): *"I noticed audio doesn't play right away either when I
click play in YouTube panes. I seem to have to hit play, then click in the video
component."* A browser that needs two clicks to play a video is not a daily
driver, and the memory note for this project says broken everyday flows outrank
polish. **This is an investigation first.** Nobody has reproduced it yet; find
the cause before writing a fix, and say which it was.

## What is known (read from the code, not run)

- `WebPaneController`'s `WKWebViewConfiguration` sets **no** media policy:
  nothing for `mediaTypesRequiringUserActionForPlayback`, no autoplay policy in
  `WKWebpagePreferences`, no `allowsAirPlayForMediaPlayback`. It runs on
  WebKit's defaults, and WebKit's embedder default for autoplay is not
  Safari's.
- The strip has a local event monitor on `leftMouseDown` that focuses the pane
  under the pointer and then returns the event
  (`StripViewController.swift`, the monitor near `self.focus(paneId)`). Focus
  moves first responder. If the web view is not first responder when the click
  lands, the page may receive the click without it counting as the activation
  that unlocks audio, or the click may be spent on focus.
- Things the app injects that a player could trip on: the fullscreen shim
  (`PaneFullscreen`, document-start, every frame, ADR-0014), the notification
  and geolocation shims, the content blocker's rule lists (YouTube's player
  and its ads are exactly what EasyList touches), the Mobile Layout user agent,
  and picture-in-picture's private preference.

## Hypotheses, in the order to test them

1. **The click is spent on focus.** Reproduce with the pane already focused and
   first responder versus not. If the first click only works when the web view
   already has the keyboard, the monitor or `takeFocus` is eating the user
   activation. Fix at the focus path, not with a media flag.
2. **Autoplay policy.** YouTube starts playback, WebKit's policy for an
   embedder allows only muted autoplay, so the video runs silent until a click
   *inside the media element* counts as a gesture on it. Check what
   `mediaTypesRequiringUserActionForPlayback` defaults to on this macOS, and
   what `WKWebpagePreferences` (public and the `_autoplayPolicy` private key,
   the way Safari's per-site "Allow All Auto-Play" is delivered) does. The
   owner's expectation is a browser's: a click on Play plays with sound.
3. **The content blocker.** Reproduce with `blocking = false` and with the site
   exempted. If the silent first play is a blocked pre-roll ad whose slot the
   player still waits on, the fix is in the rule handling or an exemption, and
   the README says so.
4. **The fullscreen shim or another injected script** wrapping a method the
   player calls during its first play. Bisect by disabling each user script.
5. **The Mobile Layout UA**, if the lane has it on.

## Acceptance Criteria

- **The cause, stated with evidence**, in the commit and the README's web
  section: which hypothesis, how it was shown, and which did not reproduce.
- One click on YouTube's Play produces picture **and sound**, in a pane that
  was not focused before the click, in a pane that was, in a popup, in a
  private lane, and in a docked lane. Same for a plain `<video controls>` with
  an audio track, and for a page that calls `video.play()` from a click handler
  (the general case YouTube is an instance of).
- **Autoplay without a gesture stays quiet.** A page that calls `play()` on
  load with sound must still be refused or muted, as in Safari's default. The
  fix must not turn every background tab into a noise source, especially
  because lanes are restored at launch. Test this side explicitly.
- A real-WebKit test using the existing local fixture server pattern
  (`WebFullscreenTests`, `WebPictureInPictureTests`): a page with a `<video>`
  that has an audio track, a click delivered through the real event path
  (not `evaluateJavaScript("video.play()")`, which carries no gesture), and an
  assertion that the element is playing **and not muted** and that the web
  view reports audio (see `web-audio-indicators.md` for the state API; if this
  task lands first, leave the state reading where that task will reuse it).
- If a setting is warranted (`web_autoplay = "gesture" | "muted" | "allow"`),
  add it with the safe default; do not add one just to have one.
- YouTube itself is checked **by hand by the owner**: tests cannot log in or
  guarantee an ad-free load. Say exactly what to try.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` (the
  configuration, ~line 1320-1360; user scripts; navigation policy where
  `WKWebpagePreferences` can be set per navigation)
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` (the
  `leftMouseDown` monitor and `focus(_:)`)
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPopup*.swift` (popups inherit the
  configuration)
- `swift/MaxPane/Tests/MaxPaneKitTests/WebFullscreenTests.swift`,
  `WebPictureInPictureTests.swift` (fixture pattern, real `<video>`)

## Constraints

- Private WebKit keys are acceptable here only the way picture-in-picture did
  it: set through a guarded call so a WebKit that drops the key leaves the
  default rather than crashing, pinned by a test, explained in a comment.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- No instant transitions; identity rules as ever.
