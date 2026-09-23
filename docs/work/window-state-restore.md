# The window comes back where you left it, fullscreen or not

The owner (2026-09-23): *"MaxPane is always opening fullscreen, instead we
should recall the previous state and position and use it so that the user's
experience is consistent."*

## Cause (read from the code)

`StripWindowController.showWindow` (~line 722-731) calls
`window?.toggleFullScreen(nil)` unconditionally on every launch unless
`MAXPANE_WINDOWED` is set. The window is created at a fixed 1600×1000
(`~line 106`) with no `setFrameAutosaveName`, so its frame is never saved either.
PRD §5.2 asked for fullscreen at launch; the owner has now overruled that for
the case where he left it windowed.

## Acceptance Criteria

- **The window's last state is remembered and restored**: fullscreen or not;
  if not, its frame (origin and size) and which display it was on. First
  launch, with nothing remembered, is fullscreen as today (the PRD's default).
- **Where it is kept**: the ledger's `app_state` table, beside
  `sidebar_collapsed` and `hidden_lane_ids` (no migration; one key, a small
  JSON value: `{"fullscreen":true}` or `{"fullscreen":false,"frame":[x,y,w,h],"screen":"<display id or name>"}`).
  Not `NSWindow.setFrameAutosaveName`: it writes to UserDefaults, which is not
  where this app keeps anything, and it cannot record fullscreen. Per
  profile, since the ledger is per profile.
- **When it is written**: on every fullscreen enter/exit (the two delegate
  callbacks that already exist, ~line 237), on window move and resize (debounced
  ~0.5 s, not per frame), and on quit. Never while a fullscreen transition is in
  flight.
- **Restore rules**: a remembered frame that is no longer on any screen (a
  display unplugged, a smaller laptop screen) is clamped onto the nearest
  screen's visible frame, keeping its size where it fits and shrinking where it
  does not; the window is never placed off screen or under the menu bar.
  A remembered fullscreen enters fullscreen after the window exists, as today,
  on the remembered display when it still exists.
- `MAXPANE_WINDOWED` still forces windowed for smoke tests, and does not write
  the state (a test run must not change what the owner comes back to).
- **Gallery/lanes layout, sidebar visibility and width** — check whether those
  are already remembered; if any is not, note it in the report and do not
  widen scope beyond the window frame and fullscreen.
- Tests: the encoding round trip; the clamp rule on a frame off every screen,
  partly off, and on a screen that no longer exists; the first-launch default;
  the delegate callbacks writing the state; `MAXPANE_WINDOWED` writing nothing.
  Whatever needs a real window uses the existing off-screen window pattern in
  the tests (a window at x: -8000 is used elsewhere).
- README: the launch paragraph, and the PRD §5.2 conflict recorded per
  README's conventions (an ADR, 0036, one page: the PRD said fullscreen at
  launch; the owner's daily use says remember).
- CHANGELOG: Changed.

## Constraints

- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
- No instant transitions where the app already animates; a restore is a
  window appearing, not an animation.
