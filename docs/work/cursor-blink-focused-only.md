# Only the focused terminal's cursor blinks, and the blink is a setting

## Problem

Every terminal on screen blinks its cursor, focused or not. On the strip that is
a few cursors; in the gallery (⌘G) it is every terminal at once, a dozen or more
blinking out of phase, which the owner called especially annoying. A blinking
cursor means "typing goes here". Only one pane can mean that at a time.

## What the owner asked for

> cursors should only blink in the focused terminal. This is especially annoying
> in gallery mode with lots of terminals. Make sure this is configurable.

## What is known (read, not run)

- The app sets no cursor options. libghostty-spm's default configuration does
  (`TerminalConfiguration.swift` ~line 355): block cursor, `cursor-style-blink
  = true`. The builder has `withCursorStyle` and `withCursorStyleBlink`.
- The library tells a surface about focus only from first-responder changes
  (`Platform/AppKit/AppTerminalView+Lifecycle.swift` ~line 43):
  `becomeFirstResponder` → `core.setFocus(true)`, `resignFirstResponder` →
  `core.setFocus(false)`, which reach `ghostty_surface_set_focus`.
- Ghostty draws an unfocused surface's cursor hollow and still. So a terminal
  that blinks while unfocused is most likely one Ghostty still believes is
  focused.
- **Hypothesis to confirm first:** a surface starts out focused, and a pane
  that never held first responder never resigns it, so it is never told
  `false`. Panes that are built, reparented into gallery tiles, or rehydrated
  after eviction without ever taking the keyboard would all blink. A second
  candidate: the app moving first responder to something that is not a terminal
  (a web view, the picker, the sidebar) by a path that skips
  `resignFirstResponder` on the old terminal. Find which with
  `TerminalDebugLog`'s `focus=` lifecycle lines before writing the fix, and say
  in the commit which it was.

## Acceptance Criteria

- **At most one terminal cursor blinks at any time**: the pane that holds the
  keyboard. Every other terminal shows a still cursor in Ghostty's unfocused
  style. Holds on the strip, in a dock, in a gallery tile, in an expanded tile,
  and in a pane maximized with ⇧⌘↩.
- **Nothing blinks when no terminal has the keyboard**: focus in a web pane, the
  ⌘O picker open, the sidebar, Settings or History frontmost, or the app in the
  background. On return, the focused terminal resumes blinking.
- **A terminal that has never been focused does not blink.** This is the likely
  bug; test it directly on a fresh surface.
- **Surfaces rebuilt or reparented keep the right state**: after eviction and
  rehydration, a lane recycled on scroll, entering and leaving the gallery, and
  maximize/restore, the focused pane blinks and no other does. The strip is the
  source of truth (`store.state.focusedPaneId` plus whether the window is key);
  push focus state to the surface from there rather than trusting first
  responder alone, if that is what the evidence supports.
- **A setting** in `ConfigSchema.swift`, category `.terminals`, read in
  `TerminalControllerPool.makeController` beside `copy-on-select`. Suggested
  shape, since "configurable" covers two wishes:
  `cursor_blink = "focused"` (default) | `"always"` | `"never"`.
  - `focused`: the behaviour above.
  - `never`: no cursor blinks anywhere, the focused one included.
  - `always`: every terminal blinks, which is today's behaviour, for anyone who
    wants it back.
  If the schema has no string-enum helper, add one rather than shipping two
  booleans whose fourth combination means nothing. Bad values are reported the
  way the schema reports any other, and fall back to the default.
- Shows in Settings under *Terminals & sessions* with a one-line description in
  the schema's voice. Applies the way `copy_on_select` does (on relaunch, marked
  so) unless a live path is cheap; say which in the README.
- **A program's own request still counts where Ghostty honours it.** An app that
  sets a steady cursor with DECSCUSR keeps it steady when focused. Do not fight
  the emulator over this; just state what happens under each setting.
- Tests, on real surfaces where the claim is about a surface: a never-focused
  terminal is told `focus=false` (or the equivalent observable); two terminals
  with focus moving between them, exactly one focused at each step; focus moving
  to a non-terminal leaves none focused; the config value reaches the rendered
  Ghostty configuration for all three settings; the schema default and TOML
  round trip. `CopyOnSelectTests.swift` is the model for config-to-surface tests.
- README: the terminal section and the settings reference. CHANGELOG: **Changed**
  for the new default, since unfocused cursors stop blinking for everyone.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaneController.swift`:
  `makeController` (~line 1015, the configuration builder), `takeFocus` and
  `applyPendingFocus` (~line 305), `setThumbnail` (~line 656).
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift`: `focus(_:)`,
  the gallery (`layoutGallery`, `expandTile`), eviction and rehydration,
  `toggleMaximizeFocusedPane`.
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift`, `ConfigSchema.swift`.
- Library, read-only: `.build/checkouts/libghostty-spm/Sources/GhosttyTerminal/`
  `Platform/AppKit/AppTerminalView+Lifecycle.swift`,
  `Surface/TerminalSurfaceCoordinator.swift` (`setFocus`, ~line 493),
  `Configuration/TerminalConfiguration.swift`.
- `swift/MaxPane/Tests/MaxPaneKitTests/CopyOnSelectTests.swift` as a pattern.

## Constraints

- Do not patch the library checkout; it is a SwiftPM dependency. If its API
  cannot set focus from outside the responder chain, say so and find the
  narrowest app-side route (a subclass hook, the focus bridge's
  `onFocusChange`, or making the view resign properly).
- Keyboard focus itself must not regress: `takeFocus`'s comment records a bug
  where a reparented pane had a live cursor and no keyboard. Cursor state and
  keyboard ownership must agree after this change, in both directions.
- No per-frame work and no timers of our own; Ghostty owns the blink.
- Do not launch the built app from the agent's shell. If Max Pane is running
  from `/Applications`, do not replace that bundle either.
