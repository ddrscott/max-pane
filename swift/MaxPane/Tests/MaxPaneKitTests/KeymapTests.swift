import AppKit
import Testing
@testable import MaxPaneKit

/// The keymap, as the config file gets to change it.
///
/// Nothing here calls `Keymap.install`. The resolved map is a value, and every
/// assertion is made against one — so these tests cannot move the keys out from
/// under the rest of the suite, which reads `Keymap.active` and expects the
/// defaults.
@Suite("keymap")
struct KeymapTests {
    private func keymap(_ entries: [String: [String]]) -> Keymap {
        Keymap(overrides: KeyBindings(entries))
    }

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    // MARK: - the chord parser

    /// The one that keeps the ⌘/ sheet honest.
    ///
    /// `HelpPanel.describe` and `KeyChord(_:)` are the two halves of the same
    /// spelling, and nothing forces them to agree except this: everything the
    /// sheet prints has to parse back to what it was printed from. Without it,
    /// a chord could render as `⌘←` and be unreadable in a config file, and the
    /// only symptom would be a user's edit silently doing nothing.
    @Test("every default chord round-trips through the way it is printed")
    @MainActor
    func describeRoundTrips() {
        for command in Command.allCases {
            let printed = HelpPanel.describe(command)
            // An unbound command prints a dash and has nothing to round-trip —
            // gather and ungather ship that way now.
            if command.chords.isEmpty {
                #expect(printed == "—", "\(command.rawValue) has no key but prints \"\(printed)\"")
                continue
            }
            let parsed = printed.split(separator: " ").map { KeyChord(String($0)) }
            #expect(
                parsed.allSatisfy { $0 != nil },
                "\(command.rawValue) prints \"\(printed)\", which does not parse back")
            #expect(
                parsed.compactMap { $0 } == command.chords,
                "\(command.rawValue) prints \"\(printed)\", which parses to something else")
        }
    }

    @Test("a chord is written the way a keyboard is described, or the way it is printed")
    func parsesBothSpellings() {
        let shiftCommandD = KeyChord(key: "d", modifiers: [.command, .shift])
        #expect(KeyChord("cmd+shift+d") == shiftCommandD)
        #expect(KeyChord("Command+Shift+D") == shiftCommandD)
        #expect(KeyChord("⇧⌘D") == shiftCommandD)
        #expect(KeyChord("⌘⇧d") == shiftCommandD)
        #expect(KeyChord("ctrl+opt+j") == KeyChord(key: "j", modifiers: [.control, .option]))
        #expect(KeyChord("alt+k") == KeyChord(key: "k", modifiers: [.option]))
    }

    /// `-` and `=` are two of the keys most likely to be rebound, and splitting
    /// a chord on `+` loses both.
    @Test("punctuation survives the separator")
    func parsesPunctuationKeys() {
        #expect(KeyChord("cmd+-") == KeyChord(key: "-", modifiers: [.command]))
        #expect(KeyChord("cmd+=") == KeyChord(key: "=", modifiers: [.command]))
        #expect(KeyChord("ctrl+cmd+\\") == KeyChord(key: "\\", modifiers: [.command, .control]))
        #expect(KeyChord("cmd+/") == KeyChord(key: "/", modifiers: [.command]))
    }

    @Test("keys with no character of their own have names")
    func parsesNamedKeys() {
        #expect(KeyChord("esc") == KeyChord(key: "\u{1b}", modifiers: []))
        #expect(KeyChord("shift+cmd+left") == KeyChord(key: "\u{2190}", modifiers: [.command, .shift]))
        #expect(KeyChord("opt+cmd+tab") == KeyChord(key: "\u{21e5}", modifiers: [.command, .option]))
        #expect(KeyChord("cmd+space") == KeyChord(key: " ", modifiers: [.command]))
    }

    @Test("nonsense is not a chord")
    func rejectsNonsense() {
        #expect(KeyChord("") == nil)
        #expect(KeyChord("cmd+") == nil)
        #expect(KeyChord("meta+q") == nil)
        #expect(KeyChord("cmd+nope") == nil)
        // A modifier on its own is not a key, however it is spelled.
        #expect(KeyChord("⌘") == nil)
        #expect(KeyChord("shift") == nil)
    }

    // MARK: - resolution

    @Test("a command not mentioned keeps the key it ships with")
    func anUnsetCommandKeepsItsDefault() {
        let map = keymap(["newTerminalLane": ["cmd+n"]])
        #expect(map.chords(for: .newTerminalLane) == [KeyChord(key: "n", modifiers: [.command])])
        for command in Command.allCases where command != .newTerminalLane {
            #expect(
                map.chords(for: command) == Keymap.defaults.chords(for: command),
                "\(command.rawValue) moved and nobody asked it to")
        }
        #expect(map.complaints.isEmpty)
    }

    /// One edit has to move all three renderings, which is the whole point of
    /// the ticket: the key that fires, the key the menu shows, and the key ⌘/
    /// prints are one value read three times.
    @Test("a rebound command is rebound everywhere at once")
    func oneEditMovesMenuKeyAndSheet() {
        let map = keymap(["openAnything": ["cmd+k"]])
        let commandK = KeyChord(key: "k", modifiers: [.command])
        #expect(map.chords(for: .openAnything) == [commandK])
        // What a menu item would carry.
        #expect(map.chords(for: .openAnything).first?.key == "k")
        // What the sheet would print.
        #expect(commandK.text == "⌘K")
        // What a web pane must not swallow.
        #expect(map.claimed.contains(commandK))
        // And the key it used to have is nobody's now.
        #expect(!map.claimed.contains(KeyChord(key: "o", modifiers: [.command])))
    }

    @Test("a command can be given more than one key, and the first is the menu's")
    func alternatesAreConfigurable() {
        let map = keymap(["openAnything": ["cmd+k", "cmd+t"]])
        #expect(map.chords(for: .openAnything).map(\.text) == ["⌘K", "⌘T"])
    }

    @Test("null unbinds a command, and takes its claim with it")
    func aCommandCanBeUnbound() throws {
        let config = try decode(#"{"keys": {"closePane": null}}"#)
        let map = Keymap(overrides: config.keys)
        #expect(map.chords(for: .closePane).isEmpty)
        #expect(!map.claimed.contains(KeyChord(key: "w", modifiers: [.command])))
        // ⇧⌘W is `closeLane`, a different command, and it is untouched.
        #expect(map.chords(for: .closeLane) == [KeyChord(key: "w", modifiers: [.command, .shift])])
        #expect(map.complaints.isEmpty)
    }

    // MARK: - the ways a file can be wrong

    /// Rebinding onto an occupied key is the common case, not an error: the
    /// user knows ⌘R is reload and is taking it anyway. What they should not
    /// have to do is remember to move `reload` in the same edit.
    @Test("a configured key beats a default one, and says whose it was")
    func configuredBeatsDefault() {
        let map = keymap(["newTerminalLane": ["cmd+r"]])
        #expect(map.chords(for: .newTerminalLane) == [KeyChord(key: "r", modifiers: [.command])])
        #expect(map.chords(for: .reload).isEmpty)
        #expect(map.complaints.contains { $0.contains("⌘R") && $0.contains("reload") })
        // ⇧⌘R is a different chord and stays where it was.
        #expect(map.chords(for: .hardReload) == [KeyChord(key: "r", modifiers: [.command, .shift])])
    }

    @Test("two configured commands on one chord: the first keeps it, and both are named")
    func twoConfiguredCommandsConflict() {
        // `reload` comes before `search` in `Command.allCases`.
        let map = keymap(["reload": ["cmd+j"], "search": ["cmd+j"]])
        #expect(map.chords(for: .reload) == [KeyChord(key: "j", modifiers: [.command])])
        #expect(map.chords(for: .search).isEmpty)
        #expect(map.complaints.contains { $0.contains("⌘J") && $0.contains("search") })
    }

    @Test("an unparseable chord leaves the command where it was, and nothing else moves")
    func aTypoCostsOnlyItself() {
        let map = keymap(["newTerminalLane": ["cmd+shft+n"], "toggleSidebar": ["cmd+e"]])
        #expect(map.chords(for: .newTerminalLane) == Keymap.defaults.chords(for: .newTerminalLane))
        #expect(map.chords(for: .toggleSidebar) == [KeyChord(key: "e", modifiers: [.command])])
        #expect(map.complaints.contains { $0.contains("cmd+shft+n") })
    }

    @Test("a command that does not exist is one line, not a broken keymap")
    func anUnknownCommandIsSkipped() {
        let map = keymap(["frobnicate": ["cmd+j"], "gather": ["cmd+e"]])
        #expect(map.chords(for: .gather) == [KeyChord(key: "e", modifiers: [.command])])
        #expect(map.complaints.contains { $0.contains("frobnicate") })
    }

    /// A key macOS answers first is a key that can never run the command. It is
    /// refused rather than accepted-with-a-warning, because accepting it ships a
    /// binding that looks set and does something else entirely.
    @Test("chords macOS or the Edit menu already own are refused")
    func systemChordsAreRefused() {
        let map = keymap(["gather": ["cmd+q"], "search": ["cmd+c"]])
        #expect(map.chords(for: .gather) == Keymap.defaults.chords(for: .gather))
        #expect(map.chords(for: .search) == Keymap.defaults.chords(for: .search))
        #expect(map.complaints.contains { $0.contains("⌘Q") && $0.contains("quits") })
        #expect(map.complaints.contains { $0.contains("⌘C") && $0.contains("copies") })
    }

    // MARK: - the file itself

    @Test("a keymap is decoded entry by entry, like the rest of the file")
    func partialConfigLeavesTheRestAlone() throws {
        let config = try decode("""
            {"snapToLanes": false,
             "keys": {"gather": "cmd+e", "openAnything": ["cmd+k", "⌘T"], "search": 7}}
            """)
        // The setting next to the keymap is untouched by it.
        #expect(config.snapToLanes == false)
        #expect(config.laneDefaultPt == Config().laneDefaultPt)
        #expect(config.keys.entries["gather"] == ["cmd+e"])
        #expect(config.keys.entries["openAnything"] == ["cmd+k", "⌘T"])
        // The wrong-typed one is dropped; the others are not.
        #expect(config.keys.entries["search"] == nil)

        let map = Keymap(overrides: config.keys)
        #expect(map.chords(for: .gather) == [KeyChord(key: "e", modifiers: [.command])])
        #expect(map.chords(for: .search) == Keymap.defaults.chords(for: .search))
    }

    @Test("no keys object at all is today's keymap, exactly")
    func noKeysObjectIsTheDefaults() throws {
        let config = try decode(#"{"fontSize": 14}"#)
        let map = Keymap(overrides: config.keys)
        for command in Command.allCases {
            #expect(map.chords(for: command) == Keymap.defaults.chords(for: command))
        }
        #expect(map.complaints.isEmpty)
    }

    /// Esc was declared by `.ungather` and listened for by nothing: the menu
    /// skipped it because it has no ⌘, and there was no other handler. The
    /// monitor now takes every chord the menu cannot carry, and `menuChord` is
    /// what divides them. `.ungather` no longer ships with Esc, so the chord is
    /// given to it here the way a config file would.
    @Test("a chord with no command key is not the menu's to carry")
    func nonCommandChordsAreNotMenuKeys() {
        let esc = keymap(["ungather": ["esc"]]).chords(for: .ungather)
        #expect(esc == [KeyChord(key: "\u{1b}", modifiers: [])])
        #expect(esc.first?.modifiers.contains(.command) == false)
        #expect(Command.ungather.menuChord == nil)
        #expect(Command.openAnything.menuChord == KeyChord(key: "o", modifiers: [.command]))
        // An unbound command has nothing for a menu item to show either.
        #expect(keymap(["closePane": []]).chords(for: .closePane).isEmpty)
    }

    /// The owner, on gather: *"It's too surprising. Let's remove the shortcuts
    /// for the feature so it's not triggered by accident."* It is still a
    /// command — the View menu lists it and `keys` can bind it — but no default
    /// chord reaches it, and ⌘G went to the view he uses instead.
    @Test("gather ships unbound, and ⌘G is the gallery's in both directions")
    func gatherIsUnboundAndCommandGIsTheGallery() {
        #expect(Keymap.defaults.chords(for: .gather).isEmpty)
        #expect(Keymap.defaults.chords(for: .ungather).isEmpty)
        #expect(Keymap.defaults.chords(for: .toggleGallery) == [KeyChord(key: "g", modifiers: [.command])])
        // No command waits behind ⌥⌘G any more: it is Google Drive's.
        let driveChord = KeyChord(key: "g", modifiers: [.command, .option])
        #expect(Command.allCases.allSatisfy { !Keymap.defaults.chords(for: $0).contains(driveChord) })
        // Still bindable by someone who wants it.
        #expect(keymap(["gather": ["cmd+e"]]).chords(for: .gather) == [KeyChord(key: "e", modifiers: [.command])])
    }
}
