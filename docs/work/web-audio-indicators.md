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
| Sidebar row (web rows) | the speaker on the row, clickable, so a lane that is scrolled off or **folded away** (ADR-0024) can be silenced without going to it |
| Folded group header | a speaker when anything hidden under it is audible; click mutes all of it |
| Gallery tile | the speaker on the tile header, clickable, at any scale the header survives |
| Status bar | `♪ 2` style count of audible panes (use the glyph, not a note); click mutes everything; with none audible, nothing is shown |
| ⌘P rows | the speaker on rows of audible lanes, so "which one is it" is one keystroke away; typing `audio` or `sound` filters to them |

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
