# ADR-0043: A Ghostty theme by name, and a terminal configuration that applies live

**Status:** Accepted
**Date:** 2026-09-23
**Context:** [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F9
**Builds on:** [ADR-0009](0009-libghostty-over-swiftterm.md) — the theme is
rendered after the configuration, and one controller backs every pane.

## The problem

`theme` meant light or dark and nothing else. Terminals were Afterglow or
Alabaster, chosen for the app rather than by anyone using it, and Ghostty ships
485 themes that libghostty-spm already has in a table in this checkout. Omarchy
has 19 coordinated themes and a key to pick one; every other terminal on the
Mac has a palette menu. The other half: `font_size` was read once, at launch,
so making the text bigger meant quitting the app.

## The decision

### Two keys, not an inline table

```toml
terminal_theme_dark = "Dracula"
terminal_theme_light = "Alabaster"
```

The critique wrote it as `terminal_theme = { dark = …, light = … }`. The file
is a flat list of keys and `[keys]` is the one nesting it has earned; an inline
table would be a new shape for the TOML parser, for the writer that keeps a
person's comments where they put them, for `ConfigField`, for the settings
window and for the ⌘E rows, in exchange for one pair of strings reading
slightly differently. Two keys was the app's own convention and is what shipped.

The names come from `GhosttyThemeCatalog.allThemes`, enumerated every time
(`TerminalThemes`). Nothing in this app repeats the list, so a library update
that adds a theme adds it here. Matching ignores case and the value is written
back as the table spells it, so `"dracula"` in a hand-edited file becomes
`Dracula` everywhere it is shown. A name that is not a theme is refused the way
a bad choice is — the key keeps its default, one line says why, and the line
carries a near miss when there is one (`"dracul"` → `such as "Dracula"`).

### The app's three colours still win

ADR-0009: a colour set beside the font is silently overwritten, because the
theme is rendered *after* the configuration. So the theme is where the palette
goes, and inside one theme the last line for a key is the one ghostty keeps.
`TerminalThemes.configuration` lays the named theme's definition down first —
its foreground and all sixteen ANSI colours — and then appends:

- **`background`**: the lane's own background, so a terminal does not paint a
  second one and show a seam under the header.
- **`cursor-color`**: the accent, because a cursor marks where the focus is,
  and the green means the same thing in a terminal that it means in the
  sidebar (ADR-0015).
- **`selection-background` + `selection-foreground = cell-foreground`**: the
  faint accent wash, over text that keeps its own colour.

None of the three is lost, for any theme. What a theme decides is everything
else, which is the part anybody choosing Dracula is choosing it for. The
unset path does not go through the catalog at all: it keeps applying
`TerminalConfiguration.afterglow` / `.alabaster`, the library's own presets, so
a file with no `terminal_theme_*` line in it renders byte for byte what it
rendered before.

### Live, measured

`TerminalController.setTheme` and `setTerminalConfiguration` re-render the whole
config and hand it to `ghostty_app_update_config` **and to
`ghostty_surface_update_config` for every live surface**. So a theme reaches a
terminal that is already on the strip, without a rebuild and without losing what
is on it. This is not assumed: `TerminalThemeSurfaceTests` puts ANSI-coloured
text on a real surface, captures it twice to prove it is still, names a theme,
and captures a third time — the pixels change and the grid does not move.

That makes the rest of the shared configuration live too, since it rides the
same push. `font_name`, `font_size`, `copy_on_select` and `cursor_blink` are
now marked `appliesLive` and the settings window says "live" rather than
"relaunch to apply". A config push puts every surface back to the config's font
size, so each pane re-applies its own ⌘= afterwards
(`terminalConfigurationDidChange`), and `cursor_blink`'s `focused` / `always`
difference is a focus report rather than a config value, so the surface is told
about focus again at the same moment.

### ⌘= / ⌘- / ⌘0 were already live, and stay per pane

They reach a terminal through `PaneController.setZoom` and have since the lane
size presets landed: per pane, on `PaneZoom.ladder`, written to the ledger, and
driven by the surface's own relative font-size actions because Ghostty carries
font size on the controller and one controller backs every pane. What was
missing was the *base* moving under them; `applyZoom` now reads the live
`font_size`, so a saved file and a zoomed pane compose instead of fighting.
The behaviour is unchanged and is now under test on a real surface.

### Where it is picked

- **Settings › Appearance**: a field to type a name into, and a `pick…` button
  with every theme under a submenu per initial, the worn one ticked and the
  app's own palette at the top to go back to. 485 segments was never an option
  and one flat menu of 485 items is not a picker either.
- **⌘E**: a `THEMES` section. With nothing typed it is a header and one line —
  `Dracula · Alabaster` — because several hundred rows under the commands is a
  wall, not a list. Typing any part of a name ranks them like every other
  scope. ↩ writes the key **the theme's own background chooses**, so picking
  Dracula sets the dark one and picking Alabaster the light one; a person who
  wants a light theme in dark mode writes the key by hand or types it into
  Settings, which is the rarer thing to want.

## What was rejected

**A `terminal_theme` with no light/dark split.** The app follows the Mac's
appearance live and always has; one palette would mean a dark terminal in a
light window.

**App-wide theme packs.** The critique rules them out and §4 of it says why:
the chrome is decided (ADR-0015), and the terminal palette is the free
variable.

**Refusing a theme whose darkness does not match its key.** `terminal_theme_dark
= "Alabaster"` is allowed and gives a light terminal in dark mode. It is a
strange thing to ask for and it is unambiguous, and a config file that argues
with you is worse than one that does what it is told.

## What would make us revisit

- libghostty-spm dropping `GhosttyTheme`, which would leave the names with no
  table behind them.
- A theme wanting to decide one of the three colours that are ours — most
  likely the selection, if a theme's own wash ever reads better on the lane
  background than the accent one does.
