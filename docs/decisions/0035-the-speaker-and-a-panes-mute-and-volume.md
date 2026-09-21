# ADR 0035 — The speaker: which pane is making sound, its mute and its volume

**Status:** Accepted · 2026-09-21
**Decides:** how a pane's sound is read, how its volume is set and what that
does not reach, where mute and volume are remembered, and where the speaker
is drawn.
**Evidence:** the work item [`docs/work/web-audio-indicators.md`](../work/web-audio-indicators.md);
`WebPaneAudio.swift`, `PaneAudio.swift`, `SpeakerMark.swift`;
`WebPaneAudioTests.swift`, `PaneAudioTests.swift`; builds on ADR-0034.

## The request

The owner: *"I think we need to have audio indicators in the app so I can
quickly mute panes as needed."* And, for the sidebar: *"replacing the bullet
square with the speaker icon. If a user clicks it, that should toggle mute. If
they right click, that should bring up a slider to adjust the volume."* The
sidebar row is built as he specified it and is not reinterpreted here.

## What WebKit has, on macOS 26

Dumped from `WKWebView`, `WKPreferences` and `WKWebViewConfiguration` with
`class_copyMethodList`, filtered for `olume`, `mute`, `audio`:

| | |
|---|---|
| public | `requestMediaPlaybackState`, `pauseAllMediaPlayback`, `setAllMediaPlaybackSuspended`: playing, paused or suspended. A muted video is "playing". No mute, no volume |
| `_isPlayingAudio` | true while an element with an audio track plays, unmuted by the page, at a page volume above zero. **KVO-observable: measured** firing on play, on pause, and on `v.volume = 0` and back. Stays true under `_setPageMuted:` (ADR-0034) |
| `_mediaMutedState`, `_setPageMuted:` | the embedder's mute. Not KVO-observable (measured), and it need not be: the mute is ours |
| `_setMediaVolumeForTesting:` | the only volume selector there is. See below |

So: a playing video the page muted is **not** making sound, and one the page
took to volume 0 is not either. That is what the API reports and what is shown.

## Decision

**Audible is playing and not muted.** `_isPlayingAudio` is observed by KVO,
one `WebAudioWatch` per web view, with no polling. Because it stays true under
our mute, "audible" is `playing && !muted`, and the muted speaker shows for as
long as the pane is muted, playing or not: a muted lane that shows nothing is
a lane you forget you muted. The indicator is held for 2 s after the sound
stops, so a notification blip is one appearance. A popup's web view is watched
and muted by the pane that opened it (`WebPopupDialog.wire` / `retire`), and
reports on that pane, which is the only place a person could find it. A
WebKit without the selector is never observed and reads as silent.

**Volume is the page-level media volume, through `_setMediaVolumeForTesting:`.**
The work item's order of preference was a private page-level volume, then a
user script over every media element, then no slider. The first exists:

- The name is WebKit's filing, not its behaviour. Disassembled from this
  macOS's WebKit, the method is four instructions: load the page proxy and
  tail-call `WebKit::WebPageProxy::setMediaVolume(float)`, which sends
  `WebPage::SetMediaVolume` to every web content process of the page and
  keeps the value for a relaunched one (`parameters.mediaVolume`). In
  WebCore, `Page::setMediaVolume` tells every media element, and
  `HTMLMediaElement::effectiveVolume()` is the element's volume **times** the
  page's. It is the multiplier legacy `WebView.setMediaVolume:` exposed as
  API for a decade. It is not a no-op outside testing.
- So it covers every `<video>` and `<audio>`, in every frame and every
  process of the page, elements added later included, with nothing to inject,
  observe or re-apply. It multiplies, so the site's own slider still means
  something and a page that sets its own volume does not escape. The page
  cannot see it.
- **It does not cover Web Audio.** `AudioContext`'s destination has a mute
  (`pageMutedStateDidChange`) and no page volume, and `effectiveVolume()`
  drops the page multiplier by name for an element attached to a
  `MediaElementAudioSourceNode`. Games, synths, some notification sounds and
  players that route through an analyser are at full volume or, muted,
  silent. The user-script route could interpose a `GainNode` by wrapping
  `AudioNode.prototype.connect` in the page's world; that is a third replaced
  prototype a page can see, reaches only the frames a script is evaluated in,
  and would be the one part of the feature not decided by WebKit. Not built.
  The README says so where the slider is described.
- There is no getter, so the pane remembers what it set. If WebKit drops the
  selector, `WebPaneAudio.volumeIsSupported` is false, the slider and
  `Volume…` are not offered, `maxpane volume` refuses with a sentence, and
  Mute still works: no slider rather than one that moves and changes nothing.
- **Not verified by measurement: the attenuation itself.** Nothing on the
  machine can hear. The page cannot observe the level (by design), WebKit has
  no getter, a Web Audio analyser is exactly the path WebCore exempts, and a
  CoreAudio process tap asks the owner for a recording permission. What is
  pinned: the selector exists and is taken, the disassembly above, playback
  and `_isPlayingAudio` survive it, the page's `v.volume` is untouched. The
  README has the check by ear.

**Zero is mute.** `volume` is 1 to 100, the last level that was not silence;
a slider at zero sets `muted` and keeps the level to come back to, which for
a drag is the level it started from and not the 1 % it passed.

**Remembered in the ledger**, migration `0017_pane_audio.sql`: `pane.muted`
and `pane.volume`, beside `zoom` and `mobile` and for their reason. The web
view is muted as it is built, before its first request, so a lane muted
yesterday, or evicted muted, never gets a sound out first. No snapshot is
published for them, as with zoom: a slider dragged across its track would
diff every lane per step. `PaneAudioCenter` (on `StripStore`) is the live
copy, seeded from the snapshot once per pane, and what every surface
observes. A private lane's pane is a row until the next open (ADR-0016) and
takes the same path. A strip file does not carry them.

**One glyph, grey.** Lucide `volume-2` and `volume-x`, the at-rest grey, one
step brighter under the pointer. Not a state colour: ADR-0015 keeps green for
agent state and orange for DONE, and sound is neither.

| Where | What |
|---|---|
| Sidebar web row | the leading status square becomes the speaker, centred on the square's slot in an 18 pt box; click toggles mute, right-click is the slider. `SpeakerMark` swallows the press (`mouseDown` with no `super`), so the table never sees it: no selection, no `rowClicked`, no reveal. Silent, its `hitTest` is nil and the row has its clicks back. The row's menu gains Mute and Volume… |
| Lane header, gallery tile | the same `SpeakerMark` between the state chip and the title; the press never becomes a header drag |
| Pane's address row | that pane's own, so a split lane can mute one page |
| Folded sidebar header | a speaker when a hidden lane is audible; click mutes them. No slider for many panes |
| Status bar | the glyph and a count; click is Mute All. Absent at zero |
| ⌘P | the glyph on the row; `audio` / `sound` lists those lanes first |

A session's row never carries the speaker: its square is agent state. In a
lane with an audible page and a muted one, audible shows.

**Commands.** Mute Pane ⌃⌘M (⌘M and ⌥⌘M are the system's), Mute Other Panes,
Mute All, in View, the lane's `⋯` and ⌘/. Mute Pane is grey on a lane with no
page; the other two are offered from a terminal too, since the noise is by
definition elsewhere, and grey only when nothing is audible. Both mute what
can be heard rather than every quiet page. `maxpane mute|unmute [LANE|all]`,
`maxpane volume LANE 0-100`, and `ls` marks `web[audible]`, `web[muted 40%]`.

**The terminal bell is left alone.** It is the system alert sound, its volume
is System Settings', and Mute All is about pages.

## Consequences

- An audible pane is not evicted (`WebPaneController.evict`), as one in
  picture-in-picture is not: music in a lane scrolled away is the ordinary
  case, and reclaiming it would stop the song.
- Four SPI selectors now, each behind a `responds(to:)` guard and pinned by a
  real-WebKit test that fails when WebKit renames one.
- ⌃⌘M is taken from pages like every ⌘ chord (`Command.claims`).
