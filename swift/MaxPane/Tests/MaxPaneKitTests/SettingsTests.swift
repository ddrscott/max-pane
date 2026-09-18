import AppKit
import Foundation
import Testing
@testable import MaxPaneKit

/// `config.toml` as a person's file: read, edited one value at a time, and
/// given back with everything else exactly as it was. See ADR-0012.
@Suite("the TOML line editor")
struct TomlDocumentTests {
    @Test("reads every kind of value the file uses")
    func readsValues() throws {
        let doc = TomlDocument(#"""
            name = "a \"quoted\" \\ path\tand\u00e9"
            literal = 'C:\no\escapes'
            count = 1_000
            negative = -4
            ratio = 0.25
            big = 1e3
            on = true
            chords = ["cmd+t", 'cmd+d', ]
            "quoted key" = 1   # a comment after
            keys.closePane = []

            [keys]
            newTerminalLane = "cmd+shift+t"   # and here
            """#)
        func value(_ key: String, _ table: String? = nil) throws -> TomlValue {
            try #require(doc.entry(key, in: table)).value.get()
        }
        #expect(try value("name") == .string("a \"quoted\" \\ path\tandé"))
        #expect(try value("literal") == .string(#"C:\no\escapes"#))
        #expect(try value("count") == .integer(1000))
        #expect(try value("negative") == .integer(-4))
        #expect(try value("ratio") == .float(0.25))
        #expect(try value("big") == .float(1000))
        #expect(try value("on") == .bool(true))
        #expect(try value("chords") == .array([.string("cmd+t"), .string("cmd+d")]))
        #expect(try value("quoted key") == .integer(1))
        #expect(try value("closePane", "keys") == .array([]))
        #expect(try value("newTerminalLane", "keys") == .string("cmd+shift+t"))
        #expect(doc.unreadable.isEmpty)
    }

    private let file = """
        # Max Pane
        lane_peek_pt = 28   # a sliver
        theme = "dark"
        mystery = 1

        [keys]
        # close with care
        closePane = "cmd+w"
        """ + "\n"

    @Test("a write changes one value's characters and nothing else")
    func editsInPlace() {
        var doc = TomlDocument(file)
        doc.set("lane_peek_pt", to: .integer(40))
        doc.set("theme", to: .string("light"))
        #expect(doc.text == file
            .replacingOccurrences(of: "lane_peek_pt = 28 ", with: "lane_peek_pt = 40 ")
            .replacingOccurrences(of: "theme = \"dark\"", with: "theme = \"light\""))
    }

    @Test("a new key goes at the end of its own table, and a missing table is made")
    func appendsWhereItBelongs() {
        var doc = TomlDocument(file)
        doc.set("snap_seconds", to: .float(0.3))
        doc.set("newTerminalLane", in: "keys", to: .array([.string("cmd+t")]))
        #expect(doc.text == """
            # Max Pane
            lane_peek_pt = 28   # a sliver
            theme = "dark"
            mystery = 1
            snap_seconds = 0.3

            [keys]
            # close with care
            closePane = "cmd+w"
            newTerminalLane = ["cmd+t"]

            """)

        var bare = TomlDocument("theme = \"dark\"\n")
        bare.set("closePane", in: "keys", to: .array([]))
        #expect(bare.text == "theme = \"dark\"\n\n[keys]\nclosePane = []\n")
    }

    @Test("a first top-level key goes above the comments that belong to a table")
    func topLevelBeforeTables() {
        var doc = TomlDocument("# header\n\n# about keys\n[keys]\nclosePane = []\n")
        doc.set("theme", to: .string("light"))
        #expect(doc.text == "# header\n\ntheme = \"light\"\n\n# about keys\n[keys]\nclosePane = []\n")
    }

    @Test("taking a key out leaves the comment above it")
    func removes() {
        var doc = TomlDocument(file)
        doc.remove("closePane", in: "keys")
        doc.remove("not-there")
        #expect(doc.text == file.replacingOccurrences(of: "closePane = \"cmd+w\"\n", with: ""))
    }

    @Test("what it cannot read is reported by line and survives every write byte for byte")
    func unreadableSurvives() throws {
        let text = """
            when = 1979-05-27
            table = { a = 1 }
            story = \"\"\"
            not a key
            \"\"\"
            [[servers]]
            theme = "dark"\r
            """
        var doc = TomlDocument(text)
        #expect(!doc.unreadable.isEmpty)
        for key in ["when", "table", "story"] {
            guard case .failure = try #require(doc.entry(key)).value else {
                Issue.record("\(key) should not read")
                return
            }
        }
        // Under an array of tables, so not a top-level `theme` at all: it is
        // `servers[0].theme`, which is not a server setting either.
        #expect(doc.entry("theme") == nil)
        #expect(ConfigFile.decode(doc).config.theme == .system)
        #expect(ConfigFile.decode(doc).problems.contains { $0.key == "servers[0].theme" })
        doc.set("lane_peek_pt", to: .integer(12))
        doc.remove("lane_peek_pt")
        #expect(doc.text == text)
    }

    @Test("a string is written so it reads back as itself")
    func quoting() throws {
        for s in ["plain", "with \"quotes\"", #"back\slash"#, "tab\tand\nnewline", "cmd+\\", "é ⌘"] {
            var doc = TomlDocument("")
            doc.set("v", to: .string(s))
            #expect(try #require(doc.entry("v")).value.get() == .string(s))
        }
        #expect(TomlValue.float(10).toml == "10.0")
        #expect(TomlValue.float(0.18).toml == "0.18")
    }
}

@Suite("config.toml into a Config")
struct ConfigFileTests {
    private func decode(_ text: String) -> (config: Config, problems: [ConfigProblem]) {
        ConfigFile.decode(TomlDocument(text))
    }

    @Test("every stored property of Config is exactly one key")
    func schemaIsComplete() {
        let properties = Set(Mirror(reflecting: Config()).children.compactMap(\.label))
        let named = ConfigField.all.map(\.name)
        // Two exemptions, both tables rather than keys: `keys` is listed from
        // `Command`, and `servers` is an array of tables drawn by the Servers
        // section (`ServersSection`) as rows you act on, not as key rows.
        // `ConfigFile.decode` reads both by name.
        #expect(Set(named) == properties.subtracting(["keys", "servers"]))
        #expect(Set(named).count == named.count)
        #expect(ConfigField.all.map(\.key).contains("lane_default_pt"))
        #expect(ConfigField.all.map(\.key).contains("relay_pty_host_path"))
        // Every group but the keyboard's and the servers' has a key in it.
        for group in ConfigGroup.allCases where group != .keyboard && group != .servers {
            #expect(ConfigField.all.contains { $0.group == group }, "\(group) is empty")
        }
    }

    @Test("every default written out reads back as the default, with no complaint")
    func defaultsRoundTrip() {
        var doc = TomlDocument("")
        for field in ConfigField.all { if let value = field.defaultValue { doc.set(field.key, to: value) } }
        let (config, problems) = ConfigFile.decode(doc)
        #expect(problems.isEmpty)
        #expect(config == Config())
    }

    @Test("a bad value costs that value, says which and why, and nothing else")
    func badValueFallsBack() {
        let (config, problems) = decode("""
            lane_min_pt = "wide"
            font_size = 15
            theme = "sepia"
            snap_to_lanes = false
            """)
        #expect(config.laneMinPt == Config().laneMinPt)
        #expect(config.theme == .system)
        #expect(config.fontSize == 15)
        #expect(config.snapToLanes == false)
        #expect(problems.map(\.key) == ["lane_min_pt", "theme"])
        #expect(problems[0].line == 1)
        #expect(problems[0].reason.contains("expected a whole number"))
        #expect(problems[0].reason.contains("using the default, 420"))
    }

    @Test("the old JSON spelling is not a setting here, and the message says the new name")
    func camelCaseHint() {
        let (config, problems) = decode("laneDefaultPt = 700\n[panes]\nx = 1\n")
        #expect(config.laneDefaultPt == Config().laneDefaultPt)
        #expect(problems.first?.reason.contains("lane_default_pt") == true)
        #expect(problems.contains { $0.reason.contains("[panes]") })
    }

    @Test("the keys table takes a chord, a list, [] or none")
    func keysTable() {
        let (config, problems) = decode("""
            [keys]
            newTerminalLane = "cmd+t"
            splitRight = ["cmd+d", "cmd+shift+e"]
            closePane = []
            closeLane = "none"
            reload = 7
            """)
        #expect(config.keys.entries["newTerminalLane"] == ["cmd+t"])
        #expect(config.keys.entries["splitRight"] == ["cmd+d", "cmd+shift+e"])
        #expect(config.keys.entries["closePane"] == [])
        #expect(config.keys.entries["closeLane"] == [])
        #expect(config.keys.entries["reload"] == nil)
        #expect(problems.map(\.key) == ["keys.reload"])
    }
}

@Suite("config.json becomes config.toml")
struct ConfigMigrationTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let json = #"""
        {
          "theme": "dark",
          "snapToLanes": false,
          "laneDefaultPt": 700,
          "lanePeekPt": 0,
          "fontSize": 14,
          "webMemorySoftFraction": 0.3,
          "editor": "code --goto %f:%l:%c",
          "relayPtyHostPath": null,
          "searchUrl": "https://duckduckgo.com/?q=%s",
          "laneMaxPt": "wide",
          "someday": true,
          "keys": { "newTerminalLane": "cmd+t", "closePane": null, "splitRight": ["cmd+d", "cmd+e"], "reload": 3 }
        }
        """#

    @Test("a config that worked before behaves identically after, and the JSON is untouched")
    func identical() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonURL = dir.appendingPathComponent("profiles/default/config.json")
        try FileManager.default.createDirectory(at: jsonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: jsonURL)
        let tomlURL = dir.appendingPathComponent("config.toml")

        #expect(try ConfigFile.migrate(json: jsonURL, to: tomlURL))
        let before = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let (after, problems, text) = ConfigFile.load(from: tomlURL)
        #expect(after == before)
        #expect(problems.isEmpty)
        #expect(try Data(contentsOf: jsonURL) == Data(json.utf8))

        let written = try #require(text)
        #expect(written.contains("lane_default_pt = 700"))
        #expect(written.contains("font_size = 14.0"))
        #expect(written.contains(#"editor = "code --goto %f:%l:%c""#))
        // Skipped then, skipped now, and said so rather than lost.
        #expect(written.contains("# lane_max_pt = \"wide\" was skipped"))
        #expect(written.contains("\"someday\""))
        #expect(written.contains("closePane = []"))
        #expect(written.contains("# reload: 3 was skipped"))
        #expect(!written.contains("relay_pty_host_path ="))
    }

    @Test("once only: an existing config.toml is never overwritten, and no JSON is no file")
    func once() throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let jsonURL = dir.appendingPathComponent("config.json")
        let tomlURL = dir.appendingPathComponent("config.toml")
        #expect(try !ConfigFile.migrate(json: jsonURL, to: tomlURL))
        #expect(!FileManager.default.fileExists(atPath: tomlURL.path))

        try Data(json.utf8).write(to: jsonURL)
        try Data("theme = \"light\"  # mine\n".utf8).write(to: tomlURL)
        #expect(try !ConfigFile.migrate(json: jsonURL, to: tomlURL))
        #expect(try String(contentsOf: tomlURL, encoding: .utf8) == "theme = \"light\"  # mine\n")
    }
}

@Suite("where config.toml lives")
struct ConfigPathTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test("$XDG_CONFIG_HOME when it is set, ~/.config when it is not")
    func xdg() {
        #expect(Profile.configRoot(environment: [:], home: home).path == "/Users/someone/.config/maxpane")
        #expect(Profile.configRoot(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home).path == "/tmp/xdg/maxpane")
        // The spec: an empty or relative value is invalid and ignored.
        #expect(Profile.configRoot(environment: ["XDG_CONFIG_HOME": ""], home: home).path == "/Users/someone/.config/maxpane")
        #expect(Profile.configRoot(environment: ["XDG_CONFIG_HOME": "rel/dir"], home: home).path == "/Users/someone/.config/maxpane")
    }

    @Test("the default profile's file is at the top; any other is under profiles/")
    func perProfile() {
        let root = Profile.configRoot(environment: ["XDG_CONFIG_HOME": "/tmp/xdg"], home: home)
        #expect(Profile().configDirectory(root: root).appendingPathComponent("config.toml").path
            == "/tmp/xdg/maxpane/config.toml")
        #expect(Profile(name: "tests").configDirectory(root: root).appendingPathComponent("config.toml").path
            == "/tmp/xdg/maxpane/profiles/tests/config.toml")
        #expect(Profile().legacyConfigPath(root: home.appendingPathComponent(".config/maxpane")).path
            == "/Users/someone/.config/maxpane/profiles/default/config.json")
    }
}

@Suite("the config store")
@MainActor
struct ConfigStoreTests {
    private func temp(_ text: String?) throws -> (dir: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.toml")
        if let text { try Data(text.utf8).write(to: file) }
        return (dir, file)
    }

    @Test("a change from the window is one line in the file, comments kept")
    func writesInPlace() throws {
        let (dir, file) = try temp("# mine\nlane_peek_pt = \"lots\"  # why not\nunknown = 3\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(path: file, watches: false)
        let peek = try #require(ConfigField.all.first { $0.key == "lane_peek_pt" })
        #expect(store.problem(for: peek) != nil)

        store.set(peek, to: .integer(40))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nlane_peek_pt = 40  # why not\nunknown = 3\n")
        #expect(store.config.lanePeekPt == 40)
        #expect(store.problem(for: peek) == nil)
        #expect(store.launched.lanePeekPt == Config().lanePeekPt)

        store.set(peek, to: nil)
        #expect(!store.isSet(peek))
        #expect(store.config.lanePeekPt == Config().lanePeekPt)
    }

    @Test("the first change makes the file, with a header saying what it is")
    func createsTheFile() throws {
        let (dir, _) = try temp(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/config.toml")
        let store = ConfigStore(path: file, watches: false)
        #expect(!store.fileExists)
        store.setChords(.closePane, to: [KeyChord("⇧⌘K")!.configText])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("# Max Pane settings."))
        #expect(text.hasSuffix("[keys]\nclosePane = [\"cmd+shift+k\"]\n"))
        #expect(store.keymap.chords(for: .closePane) == [KeyChord(key: "k", modifiers: [.command, .shift])])
        store.setChords(.closePane, to: nil)
        #expect(!store.isSet(.closePane))
    }

    /// A text editor saving the file, both ways editors save.
    @Test("an edit made outside the app is read back and announced")
    func externalEdit() async throws {
        let (dir, file) = try temp("theme = \"dark\"\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(path: file)
        var announced = 0
        let token = NotificationCenter.default.addObserver(forName: ConfigStore.didChange, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { announced += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        func settle(_ done: () -> Bool) async throws {
            for _ in 0..<120 where !done() { try await Task.sleep(nanoseconds: 25_000_000) }
        }

        try Data("theme = \"light\"\nfont_size = 16\n".utf8).write(to: file, options: .atomic)
        try await settle { store.config.fontSize == 16 }
        #expect(store.config.theme == .light)
        #expect(announced >= 1)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("font_size = \"huge\"\n".utf8))
        try handle.close()
        try await settle { store.config.fontSize == Config().fontSize }
        #expect(store.problems.first?.key == "font_size")
    }
}

@Suite("chords in the settings window")
@MainActor
struct SettingsChordTests {
    @Test("every default chord, spelled the way the file is written, reads back as itself")
    func configSpelling() {
        for command in Command.allCases {
            for chord in Keymap.defaults.chords(for: command) {
                #expect(KeyChord(chord.configText) == chord, "\(command): \(chord.configText)")
            }
        }
        #expect(KeyChord(key: "d", modifiers: [.command, .shift]).configText == "cmd+shift+d")
        #expect(KeyChord(key: "\u{2190}", modifiers: [.command]).configText == "cmd+left")
    }

    private func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)!
    }

    @Test("a recorded key press is the chord the map would store")
    func recording() {
        #expect(KeyChord(event: press("{", code: 33, [.command, .shift])) == KeyChord(key: "[", modifiers: [.command, .shift]))
        #expect(KeyChord(event: press("K", code: 40, [.command, .shift])) == KeyChord(key: "k", modifiers: [.command, .shift]))
        #expect(KeyChord(event: press("\u{F702}", code: 123, [.command, .function])) == KeyChord(key: "\u{2190}", modifiers: [.command]))
        #expect(KeyChord(event: press(",", code: 43, [.command])) == Keymap.defaults.chords(for: .showSettings).first)
    }

    @Test("⌘, opens settings, from the app menu")
    func command() {
        #expect(Command.showSettings.menu == .app)
        #expect(Command.showSettings.menuChord?.text == "⌘,")
        #expect(KeyComplaint.mentions("⌘G: gather does not get it — toggleGallery is also set to it", .gather))
        #expect(KeyComplaint.mentions("⌘G: gather does not get it — toggleGallery is also set to it", .toggleGallery))
        #expect(!KeyComplaint.mentions("ungather: \"x\" is not a chord", .gather))
    }
}

/// The settings window, in both appearances, at the top and at the keyboard.
/// Gated on `MAXPANE_SHOTS`.
@Suite("settings rendering")
@MainActor
struct SettingsRenderTests {
    @Test("renders the settings window")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.toml")
        try Data("""
            # mine
            lane_default_pt = 700
            lane_peek_pt = "lots"
            theme = "dark"
            editor = "hx %f:%l:%c"
            laneMaxPt = 900

            [keys]
            closePane = []
            newTerminalLane = "cmd+r"
            splitDown = "cmd+?"
            """.utf8).write(to: file)
        let store = ConfigStore(path: file, legacyPath: nil, watches: false)

        var open: [Popup] = []
        for (name, group) in [("top", ConfigGroup.lanes), ("editor", ConfigGroup.editorSearch), ("keyboard", ConfigGroup.keyboard)] {
            try AppearanceSheet.render(to: dir, named: "settings-\(name)") {
                let popup = SettingsWindow(store: store) { _ in }
                open.append(popup)
                // The panel already has the window's size and its content
                // follows it. Setting the content's frame by hand, as the
                // smaller popups' sheet does, lets layout shrink it to its
                // fitting height, which for a scrolling window is the header.
                let panel = try #require(popup.window)
                let content = try #require(panel.contentView)
                #expect(content.frame.size == SettingsWindow.size)
                content.layoutSubtreeIfNeeded()
                #expect(content.frame.size == SettingsWindow.size, "layout shrank the popup's content")
                // Every row fits beside the left column, scroller and all.
                let scroll = try #require(content.subviews.compactMap { $0 as? NSScrollView }.first)
                let rows = try #require(scroll.documentView?.subviews.first)
                #expect(rows.fittingSize.width <= scroll.contentView.bounds.width, "a row is wider than the window")
                #expect(rows.frame.height > 2000, "the rows were not laid out")
                popup.reveal(group, animated: false)
                return content
            }
        }
    }
}
