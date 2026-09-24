import AppKit
import GhosttyTerminal
import GhosttyTheme

/// Ghostty's theme table, and the three colours of ours that go on top of it.
///
/// `terminal_theme_dark` and `terminal_theme_light` name a theme each. The
/// names are **enumerated from the table**, never listed here: libghostty-spm
/// ships `GhosttyThemeCatalog.allThemes`, and a hard-coded copy would be a
/// second list to drift against the one that has the colours in it.
///
/// Two keys and not one `terminal_theme = { dark = …, light = … }`: the file is
/// a flat list of keys, and `keys` is the one nesting it earns (`Config`). An
/// inline table would be a second shape for the parser, the writer that keeps
/// comments, the settings window and the ⌘E rows to learn, for a pair of
/// strings that read perfectly well as a pair of keys.
///
/// **The app's three colours still win.** ADR-0009: Ghostty renders the theme
/// *after* the configuration, so colours set beside the font are overwritten —
/// which is why the palette is a `TerminalTheme` and not config lines. Inside
/// one theme the last line wins, so a named theme's definition is laid down
/// first and the background, the cursor and the selection wash are appended
/// after it. A pane keeps the lane's own background (no seam under the
/// header), the accent cursor (a cursor marks where focus is) and the readable
/// selection (`cell-foreground`, so a selected `ls` keeps its colours);
/// everything else — the sixteen ANSI colours and the foreground — comes from
/// the theme that was named.
enum TerminalThemes {
    /// Every theme in the table, in the catalog's order, which is alphabetical.
    static var all: [GhosttyThemeDefinition] { GhosttyThemeCatalog.allThemes }

    /// Every name, for the settings picker and the ⌘E rows.
    static var names: [String] { all.map(\.name) }

    /// The theme with this name, matched without regard to case so
    /// `terminal_theme_dark = "dracula"` finds `Dracula`.
    static func definition(named name: String) -> GhosttyThemeDefinition? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.name.lowercased() == wanted }
    }

    /// What the app uses when the key is unset, by name — the two Ghostty
    /// themes ADR-0009 built the palette on.
    ///
    /// The unset path does **not** go through the catalog: it keeps using
    /// `TerminalConfiguration.afterglow` / `.alabaster`, the presets the
    /// library has always applied, so nothing about a file with no
    /// `terminal_theme_*` line in it changes. These names are what the
    /// settings window and the ⌘E rows print for "no theme named".
    static let defaultDark = "Afterglow"
    static let defaultLight = "Alabaster"

    /// The nearest name to something that is not one, for the complaint a bad
    /// value gets: the first theme that contains what was typed, so
    /// `"dracla"` says nothing and `"drac"` says Dracula.
    static func suggestion(for name: String) -> String? {
        let typed = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard typed.count >= 2 else { return nil }
        return all.first { $0.name.lowercased().contains(typed) }?.name
    }

    /// How a bad `terminal_theme_*` value is refused: the same shape as a bad
    /// choice, with a name to try when one is close.
    static func complaint(about name: String) -> String {
        let base = "no Ghostty theme is called \"\(name)\" — \(all.count) themes; try ⌘E and type a name"
        guard let near = suggestion(for: name) else { return base }
        return base + ", such as \"\(near)\""
    }

    /// One half of the palette: the named theme, then our three colours.
    ///
    /// `appearance` is the mode the colours are resolved in, not the theme's
    /// own darkness — a person who puts a light theme in `terminal_theme_dark`
    /// gets a light terminal in dark mode, which is what they asked for.
    @MainActor
    static func configuration(
        named name: String?, appearance: NSAppearance.Name
    ) -> TerminalConfiguration {
        let base: TerminalConfiguration
        if let name, let definition = definition(named: name) {
            base = definition.toTerminalConfiguration()
        } else {
            base = appearance == .aqua
                ? TerminalConfiguration.alabaster : TerminalConfiguration.afterglow
        }
        return TerminalConfiguration(startingFrom: base) { builder in
            builder.withBackground(TerminalControllerPool.hex(Theme.laneBackground, in: appearance))
            builder.withCursorColor(TerminalControllerPool.hex(Theme.accent, in: appearance))
            builder.withSelectionBackground(
                TerminalControllerPool.hex(TerminalControllerPool.selectionWash, in: appearance))
            builder.withSelectionForeground("cell-foreground")
        }
    }

    /// The palette both ways, as the controller takes it.
    @MainActor
    static func theme(dark: String?, light: String?) -> TerminalTheme {
        TerminalTheme(
            light: configuration(named: light, appearance: .aqua),
            dark: configuration(named: dark, appearance: .darkAqua))
    }

    /// The palette this config asks for.
    @MainActor
    static func theme(for config: Config) -> TerminalTheme {
        theme(dark: config.terminalThemeDark, light: config.terminalThemeLight)
    }
}
