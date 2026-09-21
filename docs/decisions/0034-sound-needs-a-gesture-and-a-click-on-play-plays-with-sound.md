# ADR 0034 — Sound needs a gesture, and a click on Play plays with sound

**Status:** Accepted · 2026-09-21
**Decides:** what a page may play without being asked; what the pane does about
a player that mutes itself; and how a pane reads whether it is making sound.
**Evidence:** the work item [`docs/work/web-first-play-silent.md`](../work/web-first-play-silent.md);
`WebMediaPlayback.swift`, `WebPaneAudio.swift`; `WebMediaPlaybackTests.swift`,
whose fixtures are the measurements below reduced to a loopback page.

## The report

The owner: *"audio doesn't play right away either when I click play in YouTube
panes. I seem to have to hit play, then click in the video component."*

## The facts

Measured in a real `WebPaneController` on macOS 26, against loopback pages with
a `<video>` that has an audio track and against youtube.com itself (logged out,
the page muted from outside so nothing was audible). Clicks were real
`mouseDown`/`mouseUp` events; the autoplay measurements evaluated no script
until they had their answer, because `evaluateJavaScript` runs with a gesture.

1. **WebKit was muting nothing, and refusing nothing.**
   `WKWebViewConfiguration().mediaTypesRequiringUserActionForPlayback` is `[]`
   on macOS. A page that called `play()` on load played **with sound**
   (`_isPlayingAudio` true, `play()` resolved), in a pane nobody had touched.
   A strip restores its pages at launch. That is the bug the work item warned
   a fix might cause, and it was already there.
2. **The focus click is not spent.** A click on a web view that is not first
   responder, in a window that is not key, reaches the page trusted, with
   `navigator.userActivation.isActive`, and a `play()` in its handler plays
   with sound at once. The same with the view first responder beforehand. The
   strip's click monitor returns the event it watches.
3. **Desktop youtube.com plays with sound unasked, and one click toggles it**,
   with the blocker off and with EasyList's 45,962 rules on, fresh and after an
   evict and rehydrate.
4. **The owner's YouTube pane is on Mobile Layout** (`pane.mobile = 1`, the
   address `m.youtube.com`, read from his ledger). m.youtube.com's player sets
   `video.muted = true` before it starts and shows TAP TO UNMUTE: the video
   runs, `_isPlayingAudio` is false, and a click on the video unmutes. It does
   this under the iPhone user agent and under an Android one; with the blocker
   on or off; and in a bare `WKWebView` with **no user scripts, no blocker and
   WebKit's default policy**. It is the mobile site's design, for a phone where
   muted is the only autoplay there is. It never asks WebKit for sound, so no
   autoplay policy changes it.
5. Under `.audio`: `play()` on load is rejected with `NotAllowedError` while
   the element has sound; the same element muted plays; a click handler's
   `play()` and the native controls play with sound in one click; desktop
   YouTube waits with its large Play button and one click plays with sound;
   m.youtube.com autoplays muted as before and one click unmutes.

Hypotheses that did not reproduce: the focus click (2), the autoplay policy as
the cause of the silence (1, 4), the content blocker (3, 4), the fullscreen,
notification, geolocation and picture-in-picture scripts (4: a view with none
of them behaves the same). The one that did: Mobile Layout (4).

Not reproduced exactly: on the logged-out m.youtube.com a single click in the
middle of the player both played and unmuted. The owner's two steps mean his
player separated them: something started playback without touching the mute
(the player's own Play, a media key), and the click on the video was TAP TO
UNMUTE. `/mobile` in the test suite is that player reduced, and without the
script below it takes exactly his two clicks.

## Decision

**Sound needs a gesture.** `mediaTypesRequiringUserActionForPlayback = .audio`
on every pane's configuration, which a popup's copies. This is Safari's default
("Stop Media with Sound"). `web_autoplay = "gesture" | "allow"`; `"allow"` is
WebKit's embedder default, for someone who wants a video lane to start by
itself. No `"muted"` third value: `.audio` already is "muted may autoplay", and
refusing muted video as well breaks every page with a silent hero clip for no
noise saved. Read when a web view is built, so it reaches panes opened after a
change.

**A click on Play plays with sound.** A user script, in the page's world, every
frame, at document start, replaces `HTMLMediaElement.prototype.play` and the
`muted` setter. When `play()` is called on a paused, muted element within a
second of a trusted click **that landed inside that element's box**, while user
activation is live, and the mute was not made during a gesture, it unmutes
first. If WebKit then refuses the play, it mutes again and retries, so the
page gets what it asked for. The limits are the design:

- A mute made during a gesture is the person's (the site's mute button) and is
  never lifted.
- A video that is already playing muted is left alone; its own tap-to-unmute
  is one click.
- A Play that is not over the video does not count. Without geometry, any
  muted clip that started within a second of any click would turn its sound
  on, and a news page's silent autoplay is not something a click on a link
  asked to hear.
- It cannot see the native controls' Play or a media key: those do not call
  the page's `play()`. A page-muted video started that way stays muted until
  it is clicked, as on a phone.

It is not keyed to YouTube or to Mobile Layout. The rule is about who muted and
who pressed Play, and a desktop page with the same player has the same problem.

**Reading sound is SPI, guarded.** `WebPaneAudio` reads `_isPlayingAudio` and
`_mediaMutedState` and sets `_setPageMuted:`. The public
`requestMediaPlaybackState` cannot tell a muted video from an audible one.
Each call looks for its selector first, as picture-in-picture's key does
(`WebPaneController.enablePictureInPicture`), so a WebKit that drops one
answers nil, never raises. Measured: `_isPlayingAudio`
is false for a page-muted video and **stays true under `_setPageMuted:`**,
which is what lets a muted pane still show that it would be making sound. The
audio indicators (`docs/work/web-audio-indicators.md`) are the intended caller;
this task uses it to assert that a click produced sound.

## Consequences

- A lane restored at launch, or a link opened in a new lane, no longer starts
  talking. Desktop YouTube opened by address waits for one click.
- Sites that fall back to muted autoplay do so, silently, as in Safari.
- The script is one more replaced prototype in the page's world, beside the
  fullscreen shim's. A page can detect it. None measured objects.
- Tests cannot log in to YouTube; the owner's check is in the README.
