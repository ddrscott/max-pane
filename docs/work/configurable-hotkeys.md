# Every shortcut configurable, with the current ones as defaults

## Problem

The keymap is hardcoded. `Command.shortcut` in
`swift/MaxPane/Sources/MaxPaneKit/Commands.swift` is a `switch` returning a
literal for each case, and it is the single source for three things: the menu
items built in `AppDelegate.buildMenu()`, the ⌘/ help sheet
(`HelpPanel.describe`), and the alternate-key monitor in
`StripWindowController.installAlternateShortcuts()`. Nothing reads the config
file, so nobody can change a key without rebuilding the app.

This is not a hypothetical want. The keymap has already been rearranged twice
under people's fingers in a week — ⌘D moved from split-down to the new-pane
picker, ⇧⌘T became a plain shell lane, ⌘Y took history — and each time the only
recourse for someone who disagreed was to edit Swift.

## What it should do

- Any command's key can be set in `~/.config/maxpane/config.json`, which is
  already per-key tolerant: setting one thing leaves everything else at its
  default, and a bad value is skipped with a line on stderr rather than taking
  the file down (`Config.init(from:)`).
- The defaults are exactly what ships today. This task changes *who decides*,
  not what the keys are.
- A command can be unbound as well as rebound — some people want ⌘W to not be
  a thing.

## The interesting decisions

These are the reason this is not a mechanical change:

- **How a chord is written.** `"cmd+shift+d"`, `"⇧⌘D"`, or a structured object?
  Whatever is chosen has to round-trip with `HelpPanel.describe`, which renders
  `⌘T ⌘D` today — the sheet must show the *effective* keys, not the defaults,
  or it becomes a lie the moment anyone edits the file.
- **Conflicts.** Two commands on one chord is the obvious user error. Detect it,
  say which won and why, and do not make the app unusable over it. AppKit will
  silently give the key to whichever menu item it finds first.
- **Chords that are not ours to take.** ⌘Q, ⌘H, ⌘Tab and friends belong to
  macOS. Decide whether to refuse them, warn, or allow with a warning.
- **The alternate key.** `Command.alternateShortcut` exists so ⌘T and ⌘D can be
  the same action; the config needs a way to express "and also this key", not
  just "instead of".
- **Esc.** `Command.ungather` declares `("\u{1b}", [])` and is deliberately
  skipped when the menu is built, with a comment saying it "lives in the
  responder chain" — but **nothing actually handles it**, so Esc does not leave
  gather view today. Either wire it or stop pretending it is bound; a keymap
  that lists a key nobody listens for is worse than one that omits it.

## Acceptance criteria

- Setting `newPane` to a different chord in the config file changes the menu
  item, the key that actually fires, and what ⌘/ prints — all three, from one
  edit.
- An unset command keeps today's key exactly.
- An unparseable or conflicting chord leaves the app working, with the reason on
  stderr, and does not silently disable an unrelated command.
- A command can be explicitly unbound.
- Tests: the chord parser round-trips against `HelpPanel.describe` for every
  `Command.allCases`, so the two renderings cannot drift; conflicts are detected;
  a partial config leaves the rest at defaults.
- README's Preferences section documents it with a worked example.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift` — the keymap, its titles and
  menu sections.
- `swift/MaxPane/Sources/MaxPane/AppDelegate.swift` — `buildMenu()`, the Edit
  menu's nil-target items.
- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift` —
  `installAlternateShortcuts()`, `perform(_:)`, `canPerform(_:)`.
- `swift/MaxPane/Sources/MaxPaneKit/Views/HelpPanel.swift` — `describe`/`render`.
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift` — the per-key decoder.

## Constraints

- `Command.allCases` driving the menu is the invariant that keeps the menu and
  the keymap from drifting. Whatever replaces the hardcoded switch must keep
  that property — an action that is not in the enum should still be impossible.
- Ghostty's own keybindings are cleared (`keybind = clear`, see ADR-0009) so the
  terminal does not swallow app shortcuts before the menu sees them. A
  user-chosen chord inherits that, but anything that re-enables Ghostty bindings
  would break every configured key at once.
- The config file must stay readable and hand-editable. It is documented as a
  flat list of numbers plus this; a nested keymap is the one nesting it earns.
