# You can see which pane is making sound, and mute it from where you see it

## Problem

The owner (2026-09-21): *"I think we need to have audio indicators in the app so
I can quickly mute panes as needed."* With a dozen web lanes, some docked, some
folded away, some evicted and restored, a sound starts and there is no way to
tell which pane it is, and no way to silence it short of finding the page's own
control. Every browser has a speaker on the tab. Max Pane has no tabs, so the
indicator goes where a lane is identified: its header, its sidebar row, its
gallery tile.

Nothing in the app reads or controls a pane's audio today (checked: no use of
media playback state, mute, or audio anywhere under `Web/` or `Views/`).

## Acceptance Criteria

### Knowing

- A web pane knows whether it is **playing audio** and whether it is **muted**,
  per pane, live. Find the API first and report what exists on this macOS:
  public (`WKWebView.requestMediaPlaybackState`, `pauseAllMediaPlayback`,
  `setAllMediaPlaybackSuspended`, `closeAllMediaPresentations`) and private
  (`_isPlayingAudio` KVO-observable, `_mediaMutedState`, `_setPageMuted:`), and
  use the narrowest that works, guarded the way picture-in-picture's private
  preference is (a WebKit that drops the key degrades to "unknown", never a
  crash), pinned by a real-WebKit test with a `<video>` that has an audio
  track. A muted-but-playing video is *not* making sound; a playing video with
  volume 0 is a judgement call: say what the API reports and go with it.
- A popup's audio belongs to the pane that opened it.

### Showing

One glyph, the same everywhere, from the app's Lucide set (`volume-2` playing,
`volume-x` muted), grey at rest; **not** a state colour, because sound is not
agent state (ADR-0015 keeps green for state and orange for DONE):

| Where | What |
|---|---|
| Lane header | the speaker beside the title while any pane in the lane is audible; the muted glyph while any is muted, playing or not. It is a button: click toggles mute for the lane's audible panes |
| Pane, in a split lane | the chrome bar carries the pane's own speaker, so a lane with two pages can mute one |
| Sidebar row (web rows) | **the owner's design, below: the speaker replaces the row's status square** |
| Folded group header | a speaker when anything hidden under it is audible; click mutes all of it |
| Gallery tile | the speaker on the tile header, clickable, at any scale the header survives |
| Status bar | `♪ 2` style count of audible panes (use the glyph, not a note); click mutes everything; with none audible, nothing is shown |
| ⌘P rows | the speaker on rows of audible lanes, so "which one is it" is one keystroke away; typing `audio` or `sound` filters to them |

#### The sidebar row, as the owner specified it (2026-09-21)

> If there is audio playing, update the session sidebar by replacing the bullet
> square with the speaker icon. If a user clicks it, that should toggle mute.
> If they right click, that should bring up a slider to adjust the volume.

He pointed at the leading mark of a web row: the small square at the row's far
left, hollow for a lane with no running process, left of the globe
(`SidebarRowViews.swift` ~line 106-128, "a filled square is a running process;
a hollow one is a lane…").

- **While a pane of that row is audible, the square becomes the speaker**
  (`volume-2`), in the same slot, same size box, grey at rest, so the row's
  grid does not move. Muted: `volume-x`, and it **stays** for as long as the
  pane is muted, playing or not, because a muted lane that shows nothing is a
  lane you forget you muted. Neither audible nor muted: the square, as today.
  The swap cross-fades (`Motion.fade`).
- **Click toggles mute.** The hit target is the mark's own box, padded to at
  least 18 pt; a click there must not also select the row or reveal the lane
  (the row's click does that; this one silences something without moving you).
  Hover shows it is a button: the cursor and a one-step brighter grey, tooltip
  `Mute` / `Unmute`.
- **Right-click on the speaker opens a volume slider**, not the row's context
  menu: a small square popover anchored to the mark with a horizontal slider
  0-100 %, the current percentage in the mono font, and a mute toggle. It
  follows `ConfirmPopup`/the lane `⋯` menu for look, closes on Esc, click-away
  or ↩, and applies **live while dragging**. Right-click anywhere else on the
  row is the row's existing menu, unchanged; add **Mute** and **Volume…** items
  there too so the keyboard and the rest of the row reach the same things.
- **Volume is per pane, 0-100 %, default 100, remembered with mute** (same
  decision about the ledger as mute: if mute gets a column, volume shares the
  migration). Setting volume to 0 is mute; unmuting from 0 returns to the last
  non-zero volume.
- **How volume is applied is the hard part; find out before designing around
  it.** WebKit has no public page-volume API. In order of preference:
  (1) a private page-level volume on `WKWebView` if one exists on this macOS
  (look for `_setMediaVolume…`/`_pageVolume`-style selectors next to
  `_setPageMuted:`; guard it as picture-in-picture's key is guarded);
  (2) a user script in every frame, document-start, that sets `.volume` on
  every `HTMLMediaElement`, watches for new ones (`MutationObserver` plus the
  `play` event in capture), re-applies when a page sets its own volume, and
  multiplies rather than overwrites where it can so the page's own slider still
  means something; this misses Web Audio (`AudioContext`) unless a `GainNode`
  is interposed by wrapping `AudioContext.prototype`/`destination`, so say
  whether Web Audio is covered;
  (3) if neither is sound, ship mute only, keep the right-click slider out,
  and say exactly why in the report. Do not ship a slider that silently does
  nothing on half the sites.
  Record the choice and its limits in the ADR.
- The same speaker-with-right-click-slider behaviour applies to the lane
  header's speaker, the chrome bar's and the gallery tile's, since they are the
  same component. The status bar's count and a folded group's speaker mute
  only; no slider for many panes at once.
- `maxpane volume LANE 0-100` beside `maxpane mute`, and `maxpane ls` shows a
  volume other than 100.

- Appears and leaves with `Motion.fade`; never snaps. A pane that plays a
  half-second notification blip should not make the header flicker: hold the
  indicator for ~2 s after audio stops.

### Muting

- **Mute is per pane, remembered for the life of the pane, not written to the
  ledger** unless there is already a natural per-pane column for it (check
  `pane.zoom`, `pane.mobile`; if adding one is a single migration like
  `0012_pane_mobile.sql`, persist it, since a lane muted yesterday and blaring
  at launch is the bug this feature exists to prevent; say which you chose).
- Commands, rebindable, in the lane `⋯` menu, the View or Navigate menu and
  the ⌘/ sheet: **Mute Pane** / **Unmute Pane** (toggle, suggest ⌃⌘M after
  checking `Commands.swift` and the system's ⌘M Minimize family), **Mute Other
  Panes**, **Mute All**. A terminal lane greys them out.
- Muting never pauses. It silences; the video keeps playing, which is what a
  browser's tab mute does and what someone watching a stream with the sound
  off wants.
- A muted pane that is evicted and rehydrated comes back muted. A private lane
  follows the same rules and writes nothing (ADR-0016).
- `maxpane ls` marks audible and muted lanes, and `maxpane mute [LANE|all]` /
  `maxpane unmute` exist on the control socket: the owner drives this app over
  Relay TTY with the screen locked, and a Mac making noise in an empty room is
  exactly when that matters.

### Terminals

- Out of scope for sound detection (a terminal's bell is the system beep), but
  decide and state what Mute All does about the bell; `visual-bell` /
  `bell-features` exist in Ghostty's config if muting it is a one-liner.

## Tests

- Real WebKit: a page with an audio-bearing `<video>`; playing flips the state,
  pausing clears it after the hold, mute silences and the state reports muted,
  unmute restores, a popup's audio reports on its opener, eviction and
  rehydration keep the mute.
- Models: header, sidebar row, folded header, status bar count, ⌘P filter, the
  2 s hold, mixed lanes (one audible pane of two).
- The sidebar mark: square when silent, `volume-2` when audible, `volume-x`
  while muted whether or not playing; a click on the mark toggles mute and
  does **not** select or reveal; a right-click on the mark opens the slider and
  a right-click elsewhere on the row opens the row's menu.
- Volume, in real WebKit: the element's effective volume follows the slider, a
  media element added after the fact is covered, a page that sets its own
  volume does not escape it, 0 reads as muted, and unmute restores the last
  non-zero value. State in the test names what is and is not covered (Web
  Audio).
- The socket ops and CLI parse.
- Render sheets for the header and sidebar with the glyph in each state, light
  and dark; look at them.

## Docs

README (a "Sound" subsection under the web lane section, the menu items, the
CLI lines, any setting), CHANGELOG (Added), ADR for the private-API choice and
for where mute is remembered.

## Constraints

- If `web-first-play-silent.md` has landed, reuse its audio-state reading; if
  not, build it here where that task can reuse it.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Identity: grey at rest, no new colour, square, no single-edge rail, no
  instant transitions.
