import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// ⌘E, and `>` in ⌘O: the picker turned on the app itself. What can be wrong
/// here is which rows exist, which are grey and why, what a setting row says
/// it will write, and what a key can and cannot be bound to — all of it pure.
@Suite("app scope")
struct AppScopeTests {
    private func chord(_ text: String) -> KeyChord { KeyChord(text)! }

    private func scope(
        unavailable: [Command: String] = [:], config: Config = Config(),
        servers: [RelayServerEntry] = []
    ) -> AppScope {
        AppScope(
            commands: AppScope.commandItems(
                file: .defaults, active: .defaults, unavailable: { unavailable[$0] }),
            settings: AppScope.settingItems(config: config),
            servers: AppScope.serverItems(entries: servers) { $0.enabled ? "connected" : "disabled" })
    }

    private func headlines(_ rows: [OmniRow]) -> [String] {
        rows.compactMap { $0.candidate?.headline }
    }

    // MARK: - the prefix and the scope

    @Test("`>` at the front of any scope is the APP scope for the rest of the line")
    func prefixJumpsScope() {
        for from in OmniScope.allCases {
            let (scope, query) = OmniScope.split(from, ">gath")
            #expect(scope == .app)
            #expect(query == "gath")
        }
        #expect(OmniScope.split(.everything, "> gather").query == "gather")
        // Without it, the line and the scope are exactly what they were.
        let same = OmniScope.split(.pages, "git status")
        #expect(same.scope == .pages && same.query == "git status")
        // `@` is the server grammar, not this one.
        #expect(OmniScope.split(.everything, "@yorkshire ls").scope == .everything)
    }

    @Test("⇥ walks five scopes, and ⇧⇥ walks them back")
    func scopeCycle() {
        var s = OmniScope.everything
        var seen: [OmniScope] = []
        for _ in 0..<5 { seen.append(s); s = s.next }
        #expect(seen == OmniScope.allCases)
        #expect(s == .everything)
        #expect(OmniScope.everything.previous == .app)
        #expect(OmniScope.app.previous == .sessions)
    }

    @Test("the APP scope never offers what you typed as a shell line")
    func noLaunchRows() {
        #expect(OmniScope.app.typedActions("ls -la").isEmpty)
        let rows = OmniRanking.build(
            query: ">ls", scope: .everything, recents: [], pages: [], bookmarks: [], sessions: [],
            destination: "→ new lane", app: scope())
        for row in rows {
            if case .item(let c) = row, case .run = c.action {
                Issue.record("a shell line was offered: \(c.headline)")
            }
        }
    }

    // MARK: - the rows

    @Test("nothing typed lists every command, then the live settings, then the servers")
    func emptyListsEverything() {
        let corpus = scope(servers: [RelayServerEntry(name: "yorkshire", url: "https://y.example")])
        let rows = corpus.rows(for: "")
        let sections = rows.compactMap { row -> String? in
            if case .section(let title, _) = row { return title } else { return nil }
        }
        #expect(sections == ["COMMANDS", "SETTINGS", "SERVERS"])
        let commands = rows.compactMap { $0.candidate }.filter {
            if case .app(.command) = $0.action { return true } else { return false }
        }
        #expect(commands.count == Command.allCases.count)
        #expect(commands.map(\.headline) == Command.allCases.map(\.title))
        // Nothing here has a "when" to print.
        #expect(rows.compactMap(\.candidate).allSatisfy { $0.chosenAt <= 0 })
    }

    @Test("a command row carries its chord on the right, or a dash")
    func chordOnTheRight() {
        let rows = scope().rows(for: "")
        let gallery = rows.compactMap(\.candidate).first { $0.headline == Command.toggleGallery.title }
        #expect(gallery?.trailing == "⌘G")
        let gather = rows.compactMap(\.candidate).first { $0.headline == Command.gather.title }
        #expect(gather?.trailing == "—")
    }

    @Test("the file's chord is shown, marked pending when it is not the running one")
    func fileChordIsShownAsPending() {
        let file = Keymap(overrides: KeyBindings(["gather": ["cmd+shift+g"]]))
        let items = AppScope.commandItems(file: file, active: .defaults, unavailable: { _ in nil })
        let gather = items.first { $0.command == .gather }!
        #expect(gather.chords == [chord("cmd+shift+g")])
        #expect(gather.pending)
        #expect(items.first { $0.command == .toggleGallery }?.pending == false)
        let row = AppScope(commands: [gather], settings: [], servers: []).rows(for: "").compactMap(\.candidate).first!
        #expect(row.detail.contains("relaunch to apply"))
    }

    @Test("a command the menu greys is grey here for the same reason, and still listed")
    func greyedRowsSayWhy() {
        let corpus = scope(unavailable: [.editAddress: "needs a page"])
        let rows = corpus.rows(for: "edit address")
        let row = rows.compactMap(\.candidate).first { $0.headline == "Edit Address" }
        #expect(row?.unavailable == "needs a page")
        #expect(row?.detail.contains("needs a page") == true)
        // Rows are selectable — you can still bind a key to a command you
        // cannot run right now.
        #expect(rows.contains { $0.isSelectable && $0.candidate?.headline == "Edit Address" })
    }

    @Test("typing ranks by where the match landed, and a guess never shares the list with a hit")
    func typingRanks() {
        let rows = scope().rows(for: "gather")
        let names = headlines(rows)
        #expect(names.first == "Gather Project")
        #expect(names.contains("Leave Gather View"))
        // "gather" scattered through some other title would be a guess;
        // with two literal hits, no guess survives.
        let matched = rows.compactMap(\.candidate)
        #expect(matched.allSatisfy { $0.quality.isLiteral })
        // And a command is found by its config-file name too.
        #expect(headlines(scope().rows(for: "toggleGallery")).contains("Toggle Gallery"))
    }

    @Test("nothing matching says so rather than showing an empty box")
    func noMatchIsANote() {
        let rows = scope().rows(for: "zzqx")
        #expect(rows.count == 1)
        if case .note(let title, let detail) = rows[0] {
            #expect(title == "APP")
            #expect(detail.contains("zzqx"))
        } else {
            Issue.record("expected a note, got \(rows[0])")
        }
    }

    // MARK: - settings

    @Test("only the live boolean and choice settings are rows, each knowing what ↩ writes")
    func liveSettingsOnly() {
        var config = Config()
        config.pasteTidy = true
        let items = AppScope.settingItems(config: config)
        let keys = Set(items.map(\.key))
        // Live, boolean or choice: in.
        #expect(keys.contains("paste_tidy"))
        #expect(keys.contains("theme"))
        #expect(keys.contains("agent_notify"))
        // Live since ADR-0043: the terminals' own switches are rows too.
        #expect(keys.contains("copy_on_select"))
        #expect(keys.contains("cursor_blink"))
        // Read at launch: out, however simple the control.
        #expect(!keys.contains("blocking"))
        // A theme is neither a toggle nor a choice — several hundred names
        // have their own rows (`themeItems`), not a row that cycles.
        #expect(!keys.contains("terminal_theme_dark"))
        // A live number: out, it is not a thing that flips.
        #expect(!keys.contains("paste_history_keep"))
        // Every row is one the schema says applies live.
        for item in items {
            let field = ConfigField.all.first { $0.key == item.key }
            #expect(field?.appliesLive == true, "\(item.key) is not live")
        }
        let tidy = items.first { $0.key == "paste_tidy" }!
        #expect(tidy.value == .bool(true))
        #expect(tidy.next == .bool(false))
        let theme = items.first { $0.key == "theme" }!
        let options = ConfigField.all.first { $0.key == "theme" }.flatMap { field -> [String]? in
            if case .choice(let o) = field.control { return o } else { return nil }
        }!
        #expect(theme.value == .string(options[0]))
        #expect(theme.next == .string(options[1]))
    }

    @Test("a setting row prints its value on the right and writes the other one")
    func settingRow() {
        var config = Config()
        config.pasteTidy = false
        let rows = scope(config: config).rows(for: "paste tidy")
        let row = rows.compactMap(\.candidate).first { $0.headline == "paste_tidy" }
        #expect(row?.trailing == "off")
        #expect(row?.action == .app(.setting(key: "paste_tidy", to: .bool(true))))
    }

    // MARK: - servers

    @Test("an enabled server offers reconnect, disable and the next colour; a disabled one offers enable")
    func serverRows() {
        let entries = [
            RelayServerEntry(name: "yorkshire", url: "https://y.example", enabled: true, color: .violet),
            RelayServerEntry(name: "attic", url: "https://a.example", enabled: false),
        ]
        let items = AppScope.serverItems(entries: entries) { $0.enabled ? "connected" : "disabled" }
        let yorkshire = items.filter { $0.name == "yorkshire" }.map(\.action)
        #expect(yorkshire == [.reconnect, .disable, .colour(.magenta)])
        #expect(items.filter { $0.name == "attic" }.map(\.action) == [.enable])
        let rows = AppScope(commands: [], settings: [], servers: items).rows(for: "attic")
        #expect(headlines(rows) == ["attic: Enable"])
        #expect(rows.compactMap(\.candidate).first?.action == .app(.server(name: "attic", .enable)))
    }

    // MARK: - binding

    @Test("a chord macOS owns is refused with the reason")
    @MainActor
    func reservedChordRefused() {
        let why = Keymap.defaults.refusal(binding: chord("cmd+q"), to: .gather)
        #expect(why?.contains("quits") == true)
    }

    @Test("a chord another command holds is refused by that command's name")
    @MainActor
    func heldChordRefused() {
        let why = Keymap.defaults.refusal(binding: chord("cmd+g"), to: .gather)
        #expect(why == "⌘G is Toggle Gallery's")
        // Its own chord, and a free one, are fine.
        #expect(Keymap.defaults.refusal(binding: chord("cmd+g"), to: .toggleGallery) == nil)
        #expect(Keymap.defaults.refusal(binding: chord("cmd+shift+g"), to: .gather) == nil)
    }

    @Test("the file's keymap is what a binding is checked against")
    @MainActor
    func checkedAgainstTheFile() {
        let file = Keymap(overrides: KeyBindings(["gather": ["cmd+shift+g"]]))
        #expect(file.refusal(binding: chord("cmd+shift+g"), to: .ungather) == "⇧⌘G is Gather Project's")
    }

    @Test("the recorder reads esc as cancel and a key as a chord")
    @MainActor
    func recorder() throws {
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(ChordRecorder.outcome(of: esc) == .cancelled)
        let key = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0,
            context: nil, characters: "G", charactersIgnoringModifiers: "G", isARepeat: false, keyCode: 5))
        #expect(ChordRecorder.outcome(of: key) == .chord(chord("cmd+shift+g")))
    }

    // MARK: - the command itself

    @Test("Run Command is a command with a key, in a menu, that nothing else has")
    @MainActor
    func runCommandIsACommand() {
        #expect(Command.runCommand.title == "Run Command…")
        #expect(Keymap.defaults.chords(for: .runCommand) == [chord("cmd+e")])
        #expect(Command.runCommand.menu == .file)
        let holders = Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord("cmd+e")) }
        #expect(holders == [.runCommand])
        #expect(Keymap.defaults.complaints.isEmpty)
    }
}

/// A picture of the APP scope, beside the other picker sheets.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("app scope rendering")
@MainActor
struct AppScopeRenderTests {
    @Test("renders the three kinds of row, one of them greyed")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        var config = Config()
        config.pasteTidy = false
        let file = Keymap(overrides: KeyBindings(["gather": ["cmd+shift+g"]]))
        let corpus = AppScope(
            commands: AppScope.commandItems(
                file: file, active: .defaults,
                unavailable: { $0.needsWebPane ? "needs a page" : nil }
            ).filter { [.gather, .toggleGallery, .editAddress, .bookmarkPage].contains($0.command) },
            settings: AppScope.settingItems(config: config).filter { ["paste_tidy", "theme"].contains($0.key) },
            servers: AppScope.serverItems(
                entries: [RelayServerEntry(name: "yorkshire", url: "https://y.example", color: .violet)]
            ) { _ in "connected · 3 sessions" })

        for width in [600.0, 780.0] as [CGFloat] {
            let rows = corpus.rows(for: "")
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
                        candidate: candidate, query: "",
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
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("omni-app-\(Int(width)).png"))
        }
    }
}
