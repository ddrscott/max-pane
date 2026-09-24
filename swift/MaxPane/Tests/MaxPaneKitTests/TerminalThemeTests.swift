import AppKit
import GhosttyTerminal
import GhosttyTheme
import Testing

@testable import MaxPaneKit

/// `terminal_theme_dark` / `terminal_theme_light`: a Ghostty theme by name,
/// with the app's three colours still on top.
@Suite("a Ghostty theme, by name")
struct TerminalThemeSettingTests {
    private func field(_ key: String) -> ConfigField? { ConfigField.all.first { $0.key == key } }

    @Test("the names come from libghostty's table, not from a list here")
    func catalogIsTheList() {
        // Whatever the library ships, this is the set: the point of the test
        // is that nothing in this app repeats it. A number, so a checkout that
        // lost the table fails loudly rather than offering two themes.
        #expect(TerminalThemes.all.count > 200)
        #expect(TerminalThemes.names.count == Set(TerminalThemes.names).count)
        #expect(TerminalThemes.names == GhosttyThemeCatalog.allThemes.map(\.name))
        // The two the app's palette has always been built on are in it, which
        // is what lets the picker print them as "the app's own".
        #expect(TerminalThemes.definition(named: TerminalThemes.defaultDark) != nil)
        #expect(TerminalThemes.definition(named: TerminalThemes.defaultLight) != nil)
        // Matched without regard to case, and trimmed.
        #expect(TerminalThemes.definition(named: "  dracula ")?.name == "Dracula")
        #expect(TerminalThemes.definition(named: "no such theme") == nil)
    }

    @Test("two keys under Appearance, unset by default, applied live")
    func schema() throws {
        #expect(Config().terminalThemeDark == nil)
        #expect(Config().terminalThemeLight == nil)
        for key in ["terminal_theme_dark", "terminal_theme_light"] {
            let row = try #require(field(key), "\(key)")
            #expect(row.group == .appearance)
            #expect(row.appliesLive)
            #expect(row.defaultValue == nil)
            guard case .themePick(let unset) = row.control else {
                Issue.record("\(key) is not a theme picker")
                continue
            }
            #expect(unset == (key.hasSuffix("dark") ? "Afterglow" : "Alabaster"))
        }
    }

    @Test("a name is written as the table spells it; anything else is refused with a suggestion")
    func decodes() {
        func decode(_ text: String) -> (Config, [ConfigProblem]) { ConfigFile.decode(TomlDocument(text)) }
        // Case does not matter going in; one spelling comes out, so the file,
        // the window and the picker cannot disagree about a theme's name.
        #expect(decode("terminal_theme_dark = \"dracula\"\n").0.terminalThemeDark == "Dracula")
        #expect(decode("terminal_theme_light = \"Alabaster\"\n").0.terminalThemeLight == "Alabaster")
        #expect(decode("font_size = 15\n").0.terminalThemeDark == nil)

        let (config, problems) = decode("terminal_theme_dark = \"dracul\"\nfont_size = 15\n")
        #expect(config.terminalThemeDark == nil)
        #expect(config.fontSize == 15)
        #expect(problems.map(\.key) == ["terminal_theme_dark"])
        #expect(problems[0].reason.contains("no Ghostty theme is called"))
        #expect(problems[0].reason.contains("Dracula"))

        let (typed, wrong) = decode("terminal_theme_light = 3\n")
        #expect(typed.terminalThemeLight == nil)
        #expect(wrong.map(\.key) == ["terminal_theme_light"])
    }

    @Test("the named theme's palette, with the app's three colours last")
    @MainActor
    func ourThreeColoursWin() throws {
        let dracula = try #require(TerminalThemes.definition(named: "Dracula"))
        var config = Config()
        config.terminalThemeDark = "Dracula"
        let lines = TerminalThemes.theme(for: config).dark.rendered
            .split(separator: "\n").map(String.init)

        // The theme is in there: its foreground and its sixteen ANSI colours.
        #expect(lines.contains("foreground = \(dracula.foreground)"))
        for index in 0...15 {
            let colour = try #require(dracula.palette[index])
            #expect(lines.contains("palette = \(index)=#\(colour)"), "palette \(index)")
        }

        // And ours are last, which is what makes them win: ADR-0009 says the
        // theme is rendered after the configuration, and inside one theme the
        // last line for a key is the one ghostty keeps.
        func last(_ prefix: String) -> String? { lines.last { $0.hasPrefix(prefix + " = ") } }
        #expect(last("background") == "background = \(TerminalControllerPool.hex(Theme.laneBackground, in: .darkAqua))")
        #expect(last("cursor-color") == "cursor-color = \(TerminalControllerPool.hex(Theme.accent, in: .darkAqua))")
        #expect(last("selection-background")
            == "selection-background = \(TerminalControllerPool.hex(TerminalControllerPool.selectionWash, in: .darkAqua))")
        #expect(last("selection-foreground") == "selection-foreground = cell-foreground")
        // The theme's own background is still written — earlier, and beaten.
        #expect(lines.contains("background = \(dracula.background)"))
        #expect(lines.firstIndex(of: "background = \(dracula.background)")!
            < lines.lastIndex(of: last("background")!)!)
    }

    @Test("unset is exactly what it was before: Afterglow and Alabaster, untouched")
    @MainActor
    func unsetIsUnchanged() {
        let theme = TerminalThemes.theme(for: Config())
        // The library's own presets, not the catalog's entries of the same
        // name — nothing about a file with no `terminal_theme_*` line changes.
        let expectedDark = TerminalConfiguration(startingFrom: .afterglow) { builder in
            builder.withBackground(TerminalControllerPool.hex(Theme.laneBackground, in: .darkAqua))
            builder.withCursorColor(TerminalControllerPool.hex(Theme.accent, in: .darkAqua))
            builder.withSelectionBackground(
                TerminalControllerPool.hex(TerminalControllerPool.selectionWash, in: .darkAqua))
            builder.withSelectionForeground("cell-foreground")
        }
        #expect(theme.dark == expectedDark)
        #expect(theme.light.rendered.contains("background = F7F7F7"))
    }
}

/// The picker: the rows ⌘E gives themes, and where ↩ writes them.
@Suite("themes in the ⌘E picker")
struct TerminalThemeScopeTests {
    private func scope(config: Config) -> AppScope {
        AppScope(
            commands: [], settings: [], servers: [],
            themes: AppScope.themeItems(config: config))
    }

    @Test("a row per theme, filed by its own darkness, with the worn one marked")
    func items() throws {
        var config = Config()
        config.terminalThemeDark = "Dracula"
        let items = AppScope.themeItems(config: config)
        #expect(items.count == TerminalThemes.all.count)
        let dracula = try #require(items.first { $0.name == "Dracula" })
        #expect(dracula.dark)
        #expect(dracula.current)
        // Nothing named for light, so Alabaster — the app's own — is what is
        // worn there.
        let alabaster = try #require(items.first { $0.name == "Alabaster" })
        #expect(!alabaster.dark)
        #expect(alabaster.current)
        #expect(items.filter(\.current).count == 2)
    }

    @Test("nothing typed says what is worn and how to change it, not several hundred rows")
    func emptyQueryIsASentence() {
        let rows = scope(config: Config()).rows(for: "")
        #expect(rows.filter(\.isSelectable).isEmpty)
        guard case .section(let title, let note)? = rows.first else {
            Issue.record("no THEMES header")
            return
        }
        #expect(title == "THEMES")
        #expect(note.contains("themes"))
        guard case .note(let worn, _)? = rows.dropFirst().first else {
            Issue.record("no worn line")
            return
        }
        #expect(worn == "Afterglow · Alabaster")
    }

    @Test("typing a name gives the row that writes it, to the key its darkness chooses")
    func typedRows() throws {
        let rows = scope(config: Config()).rows(for: "dracula")
        let dracula = try #require(rows.compactMap(\.candidate).first { $0.headline == "Dracula" })
        #expect(dracula.action == .app(.terminalTheme(name: "Dracula", dark: true)))
        #expect(dracula.detail.contains("dark mode"))

        let light = scope(config: Config()).rows(for: "alabaster")
        let alabaster = try #require(light.compactMap(\.candidate).first { $0.headline == "Alabaster" })
        #expect(alabaster.action == .app(.terminalTheme(name: "Alabaster", dark: false)))
        #expect(alabaster.trailing == "worn")

        // A word that is not a theme does not pick one up out of the table.
        #expect(scope(config: Config()).rows(for: "zzzznope").compactMap(\.candidate).isEmpty)
    }
}

/// The same on real surfaces: a theme and a font size that reach a terminal
/// already on the strip, measured rather than assumed.
///
/// Nothing here touches the shared controller — a controller follows the
/// appearance of the surfaces it minted, and this suite deliberately changes
/// both (`TerminalControllerPool.makeController`).
@Suite("a live terminal takes a new theme and a new font", .serialized)
@MainActor
struct TerminalThemeSurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "theme-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        var claims = 0
        var lastClaim: (cols: Int, rows: Int) = (0, 0)
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) {
            claims += 1
            lastClaim = (cols, rows)
        }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let controller: TerminalController
        let wire = Wire()
        var config: Config

        init(config: Config) async throws {
            self.config = config
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-terminal-theme-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "theme", near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Pinned, so the half of the theme under test is the half that
            // renders however this Mac's System Settings are set.
            window.appearance = NSAppearance(named: .darkAqua)
            controller = TerminalControllerPool.makeController(for: config)
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: controller)
            // What the strip sets: the live file, which is what makes a save
            // reach this pane.
            pane.liveConfig = { [unowned self] in self.config }
            pane.attach(wire)
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 400)
            window.contentView?.addSubview(pane.view)
            window.contentView?.layoutSubtreeIfNeeded()
            try await quiet()
        }

        /// The surface reports its viewport several times while it settles on
        /// a cell size; measuring before that measures nothing.
        func quiet() async throws {
            var still = 0, last = -1
            for _ in 0..<240 where still < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                still = (wire.claims == last && wire.claims > 0) ? still + 1 : 0
                last = wire.claims
            }
        }

        func prints(_ text: String) async throws {
            wire.onData?(ArraySlice(Array(text.utf8)))
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        /// The file was saved: exactly what the window does on `didChange`.
        func save(_ change: (inout Config) -> Void) async throws {
            change(&config)
            TerminalControllerPool.applyLive(config, to: controller)
            pane.terminalConfigurationDidChange()
            try await quiet()
        }

        func picture() async -> Data? {
            await withCheckedContinuation { continuation in
                pane.capture(fullPage: false) { continuation.resume(returning: try? $0.get()) }
            }
        }

        func close() {
            pane.tearDown()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("a theme named after the pane was built reaches it, and does not resize it")
    func themeIsLive() async throws {
        let rig = try await Rig(config: Config())
        defer { rig.close() }
        // Text in the ANSI colours, which is the half of the palette a theme
        // owns — the background and the cursor stay ours either way.
        try await rig.prints("\u{1b}[31mRED\u{1b}[32mGREEN\u{1b}[34mBLUE\u{1b}[0m\r\n")
        let before = await rig.picture()
        #expect(before != nil)
        // Twice, so "the picture changed" means the palette and not a cursor
        // that happened to be up in one of them.
        #expect(await rig.picture() == before, "the surface is still between captures")
        let grid = rig.wire.lastClaim

        try await rig.save { $0.terminalThemeDark = "Dracula" }
        #expect(rig.controller.theme == TerminalThemes.theme(for: rig.config))
        #expect(rig.controller.renderedConfig.contains("palette = 1="))

        let after = await rig.picture()
        #expect(after != nil)
        // The measurement: the same surface, never rebuilt, drawing different
        // pixels. Ghostty pushes the re-rendered config at every live surface
        // (`ghostty_surface_update_config`), so this is a repaint and not a
        // new pane.
        #expect(before != after, "the surface repainted in the new palette")
        // And the grid did not move, so nothing was reflowed or re-claimed at
        // the far end by a palette.
        #expect(rig.wire.lastClaim == grid)
    }

    @Test("font_size applies as the file is saved, and the pane's own ⌘= still steps from it")
    func fontSizeIsLive() async throws {
        let rig = try await Rig(config: Config())
        defer { rig.close() }
        let before = rig.wire.lastClaim
        #expect(before.cols > 0)

        try await rig.save { $0.fontSize = 26 }
        let after = rig.wire.lastClaim
        // Twice the points is about half the columns in the same lane. Loose
        // bounds: the exact cell width is the font's business.
        #expect(after.cols < before.cols * 3 / 4, "\(before.cols) → \(after.cols)")
        #expect(after.cols > before.cols / 3, "\(before.cols) → \(after.cols)")

        // ⌘- on top of the new size, not on top of the old one.
        rig.pane.setZoom(0.5)
        try await rig.quiet()
        #expect(rig.wire.lastClaim.cols > after.cols)
    }

    @Test("⌘= / ⌘- / ⌘0 change one pane's font, live, and the ledger remembers which")
    func zoomIsPerPane() async throws {
        let rig = try await Rig(config: Config())
        defer { rig.close() }
        let actual = rig.wire.lastClaim

        rig.pane.setZoom(PaneZoom.next(from: 1, up: true))
        try await rig.quiet()
        let bigger = rig.wire.lastClaim
        #expect(bigger.cols < actual.cols, "\(actual.cols) → \(bigger.cols)")
        // Per pane, in the ledger, exactly as a web pane's zoom is.
        #expect(rig.store.state.lanes[0].panes[0].id == rig.pane.paneId)
        #expect(rig.pane.zoom > 1)

        rig.pane.setZoom(1)
        try await rig.quiet()
        #expect(rig.wire.lastClaim == actual)
    }
}

/// A picture of the theme rows, beside the other picker sheets.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("theme row rendering")
@MainActor
struct TerminalThemeRenderTests {
    @Test("the header, the worn pair, and a few themes as typed rows")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        var config = Config()
        config.terminalThemeDark = "Dracula"
        let corpus = AppScope(
            commands: [], settings: [], servers: [],
            themes: AppScope.themeItems(config: config))

        for (name, query) in [("themes-empty", ""), ("themes-typed", "dra")] {
            let width: CGFloat = 780
            let rows = corpus.rows(for: query)
            let shortcuts = OmniRanking.shortcuts(for: rows)
            let heights = rows.map { $0.isSelectable ? 42.0 : 26.0 as CGFloat }
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: heights.reduce(0, +) + 12))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.laneBackground.cgColor
            var y = sheet.bounds.height - 6
            for (index, (row, height)) in zip(rows, heights).enumerated() {
                let view: NSView
                switch row {
                case .section(let title, let note): view = PaletteSectionRow(title: title, note: note)
                case .note(let title, let detail): view = PaletteSectionRow(title: title, note: detail)
                case .item(let candidate):
                    view = OmniPickerRow(
                        candidate: candidate, query: query,
                        shortcut: shortcuts[index].map(OmniRanking.label(forShortcut:)))
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("omni-\(name).png"))
        }
    }
}
