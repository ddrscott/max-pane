# Selecting text in a terminal copies it; make that a setting, off by default

## Problem

Selecting text in a terminal pane silently replaces the clipboard. The owner
highlights by accident all the time, and each accident destroys whatever was
copied on purpose a moment before. He hates the feature and did not know the
app was doing it.

## Cause (found, not guessed)

`TerminalPaneController.swift`, in the `TerminalConfiguration` builder around
line 1031:

```swift
// Selecting text puts it on the clipboard, as it did before
// the migration and as it does in Relay. Ghostty's own
// default is off.
builder.withCustom("copy-on-select", "true")
```

It was turned on during the libghostty migration (ADR-0009) to match what
SwiftTerm's auto-copy subclass did. Ghostty's own default is off. The owner has
now overruled the reason in that comment.

## Acceptance Criteria

- A new boolean setting in `ConfigSchema.swift`, category `.terminals`, using
  the existing `bool(...)` helper. Suggest `copyOnSelect`, which the schema
  snake-cases to `copy_on_select` in `config.toml`. **Default `false`.**
- The builder passes `"copy-on-select"` as `"true"` or `"false"` from the
  config rather than a literal. Pass `"false"` explicitly when off; do not rely
  on omitting the line, so the behaviour does not move if libghostty's default
  ever does.
- With the setting off: selecting text in a terminal leaves
  `NSPasteboard.general` untouched. **⌘C and Edit › Copy still copy the
  selection**, as do any right-click copy items. Check this by hand or in a
  test, since it is the way to copy once auto-copy is gone.
- With the setting on: behaviour is exactly today's.
- The setting appears in the Settings window under *Terminals & sessions* with
  a one-line description in the schema's voice, for example: "Selecting text
  in a terminal copies it. Off, ⌘C copies."
- **Changing it applies without a relaunch** if the other terminal settings do
  (`fontName` and `fontSize` go through the same builder; follow whatever path
  they take when `ConfigWatch` sees the file change). If libghostty only reads
  it when a surface is built, say so in the description and in the README
  rather than pretending otherwise.
- An existing `config.toml` with no such line gets the new default, off. No
  migration and no line written into the user's file unasked.
- Check for a **second source**: grep for any other path that writes the
  pasteboard on selection (a selection delegate, a mouse-up handler, the
  ⌘-click gesture code). The grep done when this was filed found only the one
  line, but the ⌘-click path in `ClickableTerminalView` was not read.
- Rewrite the comment at the call site so it no longer argues for `true`.
- Tests: the schema default is `false`; the key round-trips through the TOML
  editor; the terminal configuration built from a config carries the matching
  `copy-on-select` value for both states (`SettingsTests.swift` and
  `AppearanceTests.swift` already test settings reaching the builder).
- README: the terminal section and the settings reference say selection does
  not copy by default and name the key. CHANGELOG: a **Changed** entry, since
  this flips behaviour for anyone who relied on it.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaneController.swift`
  (~line 1015–1040, the configuration builder; ~line 344, the clipboard mark)
- `swift/MaxPane/Sources/MaxPaneKit/ConfigSchema.swift` (~line 204, the
  `.terminals` entries; line 125, the `bool` helper)
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift` (the stored property and its
  default)
- `swift/MaxPane/Sources/MaxPaneKit/Views/SettingsWindow.swift` (renders from
  the schema; confirm a bool in `.terminals` shows up with no extra work)
- `swift/MaxPane/Tests/MaxPaneKitTests/SettingsTests.swift`,
  `AppearanceTests.swift`

## Constraints

- Default off. This is the owner's call and is not to be reopened on the
  grounds of parity with Relay or the pre-migration behaviour.
- Do not touch paste (`TerminalPaste`), which is deliberately not Ghostty's.
- Do not launch the built app from the agent's shell to verify.
