import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

// serial pass: real WebKit surfaces, settled against the wall clock. The whole
// suite runs in `scripts/test.sh`'s second, --no-parallel pass; see README,
// "The serial pass".

/// `[[apps]]`: a chord per web app. What can be wrong here is what the file
/// parses to, which chord each app ends up with once every command has had
/// its say, which lane counts as "already open", and what the four surfaces
/// say about all three. Pure, every one of them — the decisions are in the
/// config decoder, the keymap and `WebApps`, and none of them needs a window.

private func webPane(_ id: String, lane: String, url: String?) -> Pane {
    Pane(id: id, laneId: lane, position: 0, kind: .web,
         relaySessionId: nil, relayServer: nil, url: url, scrollY: nil, dataStoreId: nil,
         snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)
}

private func ptyPane(_ id: String, lane: String) -> Pane {
    Pane(id: id, laneId: lane, position: 0, kind: .pty,
         relaySessionId: "s", relayServer: nil, url: nil, scrollY: nil, dataStoreId: nil,
         snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)
}

private func lane(_ id: String, focusedAt: Int64 = 0, title: String? = nil, panes: [Pane]) -> Lane {
    Lane(id: id, ordinal: 1, widthPt: 500, title: title, projectRoot: nil, projectSource: .cwd,
         createdAt: 0, lastFocusAt: focusedAt, keepLive: false, dock: nil, span: 1,
         isPrivate: false, panes: panes)
}

// MARK: - the file

@Suite("[[apps]] in config.toml")
struct WebAppConfigTests {
    private func decode(_ text: String) -> (config: Config, problems: [ConfigProblem]) {
        ConfigFile.decode(TomlDocument(text))
    }

    @Test("name, url, key and docked, in file order")
    func parsesTables() {
        let (config, problems) = decode("""
            [[apps]]
            name = "Gmail"
            url = "https://mail.google.com"
            key = "ctrl+opt+cmd+g"

            [[apps]]
            name = "Linear"
            url = "linear.app"
            key = "⌃⌥⌘L"
            docked = "right"
            """)
        #expect(problems.isEmpty)
        #expect(config.apps.map(\.name) == ["Gmail", "Linear"])
        #expect(config.apps[0].docked == nil)
        #expect(config.apps[1].docked == .right)
        // A bare host is read as https, the way the address bar reads one.
        #expect(config.apps[1].pageURL?.absoluteString == "https://linear.app")
        #expect(config.apps[1].domain == "linear.app")
        // Both chord spellings parse, because there is one parser.
        #expect(config.apps[0].chord == KeyChord(key: "g", modifiers: [.control, .option, .command]))
        #expect(config.apps[1].chord == KeyChord(key: "l", modifiers: [.control, .option, .command]))
    }

    @Test("an app with no name, no url or a url that is not one is skipped, and says which")
    func skipsUnusable() {
        let (config, problems) = decode("""
            [[apps]]
            url = "https://a.com"

            [[apps]]
            name = "B"

            [[apps]]
            name = "C"
            url = "file:///etc/passwd"

            [[apps]]
            name = "D"
            url = "https://d.com"
            """)
        #expect(config.apps.map(\.name) == ["D"])
        #expect(problems.contains { $0.reason.contains("an app needs a name") })
        #expect(problems.contains { $0.reason.contains("an app needs a url") })
        #expect(problems.contains { $0.reason.contains("url must be a host") })
    }

    @Test("two apps of one name: the first keeps it, because the name is the identity")
    func refusesDuplicateNames() {
        let (config, problems) = decode("""
            [[apps]]
            name = "Mail"
            url = "https://one.com"

            [[apps]]
            name = "mail"
            url = "https://two.com"
            """)
        #expect(config.apps.map(\.url) == ["https://one.com"])
        #expect(problems.contains { $0.reason.contains("already named \"Mail\"") })
    }

    @Test("an edge nobody has costs the edge, and a key nobody can press costs the key")
    func partialFailuresAreLocal() {
        let (config, problems) = decode("""
            [[apps]]
            name = "Gmail"
            url = "https://mail.google.com"
            key = "ctrl+opt+cmd+g"
            docked = "middle"
            colour = "blue"
            """)
        #expect(config.apps.count == 1)
        #expect(config.apps[0].docked == nil)
        #expect(config.apps[0].chord != nil)
        #expect(problems.contains { $0.reason.contains("is not an edge") })
        #expect(problems.contains { $0.reason.contains("not an app setting") })
    }

    @Test("the section is written and read back with the comments left where they were")
    @MainActor
    func writesInPlace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.toml")
        try """
            # mine
            font_size = 14

            [[apps]]
            name = "Gmail"     # the one I actually read
            url = "https://mail.google.com"
            """.write(to: path, atomically: true, encoding: .utf8)

        let store = ConfigStore(path: path, watches: false)
        store.setAppChord(named: "gmail", to: "ctrl+opt+cmd+g")
        store.setAppDocked(named: "Gmail", to: .left)
        store.addApp(WebAppEntry(name: "Linear", url: "https://linear.app", key: "ctrl+opt+cmd+l"))

        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.contains("# mine"))
        #expect(text.contains("# the one I actually read"))
        #expect(text.contains("font_size = 14"))
        #expect(store.config.apps.map(\.name) == ["Gmail", "Linear"])
        #expect(store.config.apps[0].docked == .left)
        #expect(store.config.apps[0].chord?.text == "⌃⌥⌘G")

        // "none" takes the line out rather than writing an empty one.
        store.setAppChord(named: "Gmail", to: "")
        #expect(!(try String(contentsOf: path, encoding: .utf8)).contains("key = \"\""))
        #expect(store.config.apps[0].chord == nil)

        #expect(store.renameApp(from: "Linear", to: "Gmail") == false)
        #expect(store.renameApp(from: "Linear", to: "Issues") == true)
        store.removeApp(named: "Issues")
        #expect(store.config.apps.map(\.name) == ["Gmail"])
    }
}

// MARK: - the second source of chords

@Suite("an app's chord, beside the commands'")
struct WebAppKeymapTests {
    private func app(_ name: String, _ key: String, url: String = "https://example.com") -> WebAppEntry {
        WebAppEntry(name: name, url: url, key: key)
    }

    @Test("a free chord is the app's, and it is not a command's")
    func bindsAFreeChord() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "ctrl+opt+cmd+g")])
        #expect(map.complaints.isEmpty)
        #expect(map.chord(forApp: "Gmail")?.text == "⌃⌥⌘G")
        #expect(map.app(for: KeyChord("ctrl+opt+cmd+g")!) == "Gmail")
        #expect(map.app(for: KeyChord("cmd+g")!) == nil)
    }

    @Test("a chord a command holds is refused by name, and the command keeps it")
    func refusesACommandsChord() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gallery", "cmd+g")])
        #expect(map.chord(forApp: "Gallery") == nil)
        #expect(map.chords(for: .toggleGallery) == [KeyChord("cmd+g")!])
        #expect(map.complaints.contains { $0.contains("⌘G") && $0.contains("toggleGallery") })
    }

    @Test("a chord the user gave a command in [keys] is that command's too")
    func refusesAConfiguredCommandsChord() {
        let map = Keymap(
            overrides: KeyBindings(["newTerminalLane": ["ctrl+opt+cmd+g"]]),
            apps: [app("Gmail", "ctrl+opt+cmd+g")])
        #expect(map.chord(forApp: "Gmail") == nil)
        #expect(map.chords(for: .newTerminalLane).contains(KeyChord("ctrl+opt+cmd+g")!))
        #expect(map.complaints.contains { $0.contains("newTerminalLane") })
    }

    @Test("a chord macOS owns is refused with the reason, not with silence")
    func refusesAReservedChord() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Quit", "cmd+q")])
        #expect(map.chord(forApp: "Quit") == nil)
        #expect(map.complaints.contains { $0.contains("macOS quits the app") })
    }

    @Test("two apps on one chord: the earlier in the file keeps it")
    func refusesAnotherAppsChord() {
        let map = Keymap(overrides: KeyBindings(), apps: [
            app("Gmail", "ctrl+opt+cmd+g"), app("GitHub", "ctrl+opt+cmd+g"),
        ])
        #expect(map.chord(forApp: "Gmail")?.text == "⌃⌥⌘G")
        #expect(map.chord(forApp: "GitHub") == nil)
        #expect(map.complaints.contains { $0.contains("the app GitHub does not get it") })
    }

    @Test("a spelling that is not a chord costs the key and nothing else")
    func reportsAnUnparseableChord() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "cmd+gg")])
        #expect(map.chord(forApp: "Gmail") == nil)
        #expect(map.complaints.contains { $0.contains("apps.Gmail") && $0.contains("is not a chord") })
        // Every command still has what it always had.
        #expect(map.chords(for: .toggleGallery) == Keymap.defaults.chords(for: .toggleGallery))
    }

    @Test("an app with no key is simply an app with no key")
    func acceptsNoKey() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "")])
        #expect(map.complaints.isEmpty)
        #expect(map.appChords.isEmpty)
    }

    @Test("a page does not get to swallow an app's ⌘-chord")
    func claimsTheChordFromAPage() {
        // The set `Command.claims` reads, without installing one globally:
        // the resolved map is a value, and so is what it takes off a page.
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "shift+cmd+g")])
        #expect(map.claimed.contains(KeyChord("shift+cmd+g")!))
        // ⇧⌘[ arrives spelling itself `{`; an app's chord goes into the set
        // both ways, exactly as a command's does.
        let bracket = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "shift+cmd+[")])
        #expect(bracket.claimed.contains(KeyChord(key: "{", modifiers: [.shift, .command])))
        // A chord with no ⌘ is never taken from a page, app or not.
        let plain = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "ctrl+opt+g")])
        #expect(plain.chord(forApp: "Gmail") != nil)
        #expect(!plain.claimed.contains(KeyChord("ctrl+opt+g")!))
    }

    @Test("the recorder refuses before it writes, and says what has the chord")
    func refusalNamesTheHolder() {
        let map = Keymap(overrides: KeyBindings(), apps: [app("Gmail", "ctrl+opt+cmd+g")])
        #expect(map.refusal(binding: KeyChord("cmd+q")!, toApp: "Linear")?.contains("macOS quits") == true)
        #expect(map.refusal(binding: KeyChord("cmd+g")!, toApp: "Linear")?.contains("Toggle Gallery") == true)
        #expect(map.refusal(binding: KeyChord("ctrl+opt+cmd+g")!, toApp: "Linear")?.contains("the app Gmail") == true)
        // Its own chord is not a collision with itself.
        #expect(map.refusal(binding: KeyChord("ctrl+opt+cmd+g")!, toApp: "Gmail") == nil)
        #expect(map.refusal(binding: KeyChord("ctrl+opt+cmd+z")!, toApp: "Linear") == nil)
        // And a command is refused an app's chord, on the same terms.
        #expect(map.refusal(binding: KeyChord("ctrl+opt+cmd+g")!, to: .search)?.contains("the app Gmail") == true)
    }
}

// MARK: - which lane the chord goes to

@Suite("the lane an app is already on")
struct WebAppMatchTests {
    private let gmail = WebAppEntry(name: "Gmail", url: "https://mail.google.com")

    @Test("any page inside the site counts, and nothing outside it does")
    func matchesByRegistrableDomain() {
        let inside = lane("a", panes: [webPane("p", lane: "a", url: "https://mail.google.com/mail/u/0/#inbox")])
        #expect(WebApps.lane(for: gmail, in: [inside])?.id == "a")
        // A subdomain of the same registrable name is the same site — which is
        // the rule, and its cost.
        let sibling = lane("b", panes: [webPane("q", lane: "b", url: "https://docs.google.com/x")])
        #expect(WebApps.lane(for: gmail, in: [sibling])?.id == "b")
        let elsewhere = lane("c", panes: [webPane("r", lane: "c", url: "https://google.com.evil.example/mail")])
        #expect(WebApps.lane(for: gmail, in: [elsewhere]) == nil)
        // A terminal lane is not a page, whatever it is running.
        #expect(WebApps.lane(for: gmail, in: [lane("d", panes: [ptyPane("t", lane: "d")])]) == nil)
        #expect(WebApps.lane(for: gmail, in: []) == nil)
    }

    @Test("several matching lanes: the most recently focused, not the leftmost")
    func picksTheMostRecentlyFocused() {
        let lanes = [
            lane("old", focusedAt: 10, panes: [webPane("p1", lane: "old", url: "https://mail.google.com")]),
            lane("new", focusedAt: 90, panes: [webPane("p2", lane: "new", url: "https://mail.google.com/u/1")]),
            lane("mid", focusedAt: 50, panes: [webPane("p3", lane: "mid", url: "https://mail.google.com")]),
        ]
        #expect(WebApps.lane(for: gmail, in: lanes)?.id == "new")
    }

    @Test("the pane to focus is the one on the app's site, not merely the lane's first")
    func picksTheAppsPane() {
        let split = lane("a", panes: [
            ptyPane("t", lane: "a"),
            webPane("w", lane: "a", url: "https://mail.google.com"),
        ])
        #expect(WebApps.pane(for: gmail, in: split)?.id == "w")
    }

    @Test("a name is matched whole first, then as the only prefix it fits")
    func resolvesNames() {
        let apps = [
            WebAppEntry(name: "Mail", url: "https://mail.google.com"),
            WebAppEntry(name: "Mailchimp", url: "https://mailchimp.com"),
            WebAppEntry(name: "Linear", url: "https://linear.app"),
        ]
        #expect(WebApps.named("mail", in: apps)?.name == "Mail")
        #expect(WebApps.named("Mailc", in: apps)?.name == "Mailchimp")
        #expect(WebApps.named("lin", in: apps)?.name == "Linear")
        // Two fit and neither is exact: refused rather than guessed at.
        #expect(WebApps.named("mai", in: apps) == nil)
        #expect(WebApps.named("nothing", in: apps) == nil)
        #expect(WebApps.named("", in: apps) == nil)
    }
}

// MARK: - the surfaces

@Suite("where an app shows up")
struct WebAppSurfaceTests {
    private let apps = [
        WebAppEntry(name: "Gmail", url: "https://mail.google.com", key: "ctrl+opt+cmd+g"),
        WebAppEntry(name: "Linear", url: "https://linear.app"),
    ]

    private func scope(openLane: @escaping (WebAppEntry) -> String? = { _ in nil }) -> AppScope {
        let keymap = Keymap(overrides: KeyBindings(), apps: apps)
        return AppScope(
            commands: [], settings: [], servers: [],
            apps: AppScope.appItems(entries: apps, file: keymap, active: keymap, openLane: openLane))
    }

    @Test("⌘E lists them under // APPS, with the chord on the right and — for none")
    func listsInThePicker() {
        let rows = scope().rows(for: "")
        let sections = rows.compactMap { if case .section(let title, _) = $0 { return title } else { return nil } }
        #expect(sections.contains("APPS"))
        let items = rows.compactMap(\.candidate)
        #expect(items.map(\.headline) == ["Gmail", "Linear"])
        #expect(items[0].trailing == "⌃⌥⌘G")
        #expect(items[1].trailing == "—")
        // The row says which of the two things ↩ will do, before it is pressed.
        #expect(items[0].detail.hasPrefix("open "))
        let open = scope(openLane: { $0.name == "Gmail" ? "inbox" : nil }).rows(for: "")
        #expect(open.compactMap(\.candidate).first?.detail == "focus inbox")
    }

    @Test("typing matches an app by its name and by its address")
    func matchesOnNameAndURL() {
        #expect(scope().rows(for: "gmail").compactMap(\.candidate).map(\.headline) == ["Gmail"])
        #expect(scope().rows(for: "linear.app").compactMap(\.candidate).map(\.headline) == ["Linear"])
        #expect(scope().rows(for: "zzz").compactMap(\.candidate).isEmpty)
    }

    @Test("an app row's action is going to it, and it has an identity of its own")
    func carriesTheAction() {
        let row = scope().rows(for: "gmail").compactMap(\.candidate).first
        #expect(row?.action == .app(.app(name: "Gmail")))
        #expect(row?.identity == "app:app:gmail")
    }

    @Test("⌘/ prints an APPS section only when there are apps")
    @MainActor
    func listsInTheHelpSheet() {
        #expect(!HelpPanel.body(apps: []).string.contains("// APPS"))
        let bound = Keymap(overrides: KeyBindings(), apps: apps).appChords
        let after = HelpPanel.body(apps: bound).string
        #expect(after.contains("// APPS"))
        #expect(after.contains("⌃⌥⌘G"))
        #expect(after.contains("Gmail"))
        // Linear has no key, so it is not on the keyboard sheet.
        #expect(!after.contains("Linear"))
    }

    @Test("`maxpane app NAME` parses, and an empty name does not")
    func parsesTheControlLine() {
        guard case .app("Gmail")? = OpenServer.parse(#"{"op":"app","name":"Gmail"}"#) else {
            Issue.record("a name did not parse")
            return
        }
        #expect(OpenServer.parse(#"{"op":"app","name":"  "}"#) == nil)
        #expect(OpenServer.parse(#"{"op":"app"}"#) == nil)
    }
}
