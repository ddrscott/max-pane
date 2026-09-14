# Every setting editable in a UI, stored as plain TOML in ~/.config/maxpane

The owner: *"all custom settings should have a UI to edit them along with the
setting getting stored in plain text in the standard Unix/linux config
directory."*

## Problem

About twenty settings (`Config.swift`: lane widths and peek, edge rails, snap,
release/rehydrate distances, data store shards, web memory fractions and sample
interval, session poll, `relayPtyHostPath`, font name and size, `editor`,
`searchUrl`) plus the whole keymap (`keys`) can only be changed by hand-editing
JSON at `~/.config/maxpane/profiles/<profile>/config.json` — a file that does not
exist until someone creates it, in a directory one level deeper than anyone
looks, documented only in source comments. `Profile.configRoot` hardcodes
`~/.config` and ignores `$XDG_CONFIG_HOME`.

## Decisions already made (do not re-open)

- **TOML**, plain `key = value` text that can carry comments.
- **Location:** `$XDG_CONFIG_HOME/maxpane/config.toml`, falling back to
  `~/.config/maxpane/config.toml`, for the default profile. Other profiles keep
  `…/maxpane/profiles/<name>/config.toml`, so test instances stay isolated.
  `MAXPANE_CONFIG` still overrides.
- **The UI and the file are equals.** The UI writes the file; a hand edit to the
  file is picked up by the running app. Writes from the UI **preserve comments,
  ordering and unknown keys** a person put there.
- **Migration:** if `config.toml` is absent and the old JSON exists, read the JSON
  once, write the TOML, and leave the JSON untouched (say so in the log and in
  the settings UI).

## Acceptance Criteria

- A settings window, ⌘, (and in the app menu), built on the shared `Popup` — square,
  centred, animated — lists **every** `Config` key, grouped (Lanes, Gallery &
  motion, Web & memory, Terminals & sessions, Editor & search, Appearance,
  Keyboard), each with its current value, its default, and a one-line
  explanation taken from the key's documentation.
- Controls fit the type: steppers/fields with ranges for numbers, toggles for
  bools, text for strings, a picker for `theme` (added by the appearance task).
- **Keyboard:** every `Command` with its effective chords, a chord recorder to
  change one, a way to unbind (`null`) and to restore the default, and
  `Keymap.complaints` (collisions, unparseable chords) shown inline.
- Each change is written to the TOML immediately and applied live where the code
  supports it; a setting that only applies on relaunch says so beside it.
- A bad value in the file is skipped with its default used — today's per-key
  fallback in `Config.init(from:)` — and the UI shows which key was ignored and why.
- Editing `config.toml` in a text editor while the app runs updates the app and
  the open settings window.
- "Reveal config file" and "Open in editor" actions; the latter opens a terminal
  lane with the `editor` setting, the same way ⌘-clicking a path does
  (`FileOpen`).
- Keys are `snake_case` in TOML (`lane_default_pt`), mapped from the Swift
  property names in one place; the `[keys]` table uses command names.
- Tests: TOML round-trip preserving comments and unknown keys; JSON → TOML
  migration; XDG path resolution with and without `$XDG_CONFIG_HOME`; bad-value
  fallback; external-edit reload. A render sheet of the settings window.
- README: a Settings section replacing the scattered "`… in the config file`"
  mentions, and the file's location stated once.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Config.swift` — every key, the per-key
  decoder, doc comments to surface as explanations.
- `swift/MaxPane/Sources/MaxPaneKit/Keymap.swift` — `KeyBindings`, chord parsing
  and printing (`KeyChord.text`), `complaints`.
- `swift/MaxPane/Sources/MaxPaneKit/Profile.swift` — `configRoot`,
  `configDirectory`, `configPath`, `MAXPANE_CONFIG`.
- `swift/MaxPane/Sources/MaxPaneKit/Views/Popup.swift`, `ConfirmPopup.swift`,
  `Theme.squareField` — the dialog frame and field style to build on.
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift`, `AppDelegate.swift` — a
  `showSettings` command and its menu item.
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/FileOpen.swift` — opening the file
  in the editor.

## Constraints

- **Comment-preserving TOML needs a real editor, not a serializer.** Swift has no
  standard one. Options: a small in-house reader/writer for the subset this file
  uses (flat keys plus one `[keys]` table) that edits lines in place, or
  `toml_edit` in `laned-core` exposed over uniffi (config parsing is
  platform-agnostic, so it fits the core). Choose one and record why in an ADR;
  do not add a dependency without that.
- Every existing key keeps its meaning and default. A config that worked before
  must behave identically after migration.
- Depends on the appearance task queued before this one for the `theme` key.
